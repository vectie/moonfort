#!/usr/bin/env python3
"""Inspect a retained SQLite database in an existing MoonFort review ZIP."""
import argparse
import base64
import csv
import io
import json
import math
import re
import sqlite3
import sys
import zipfile
from contextlib import contextmanager
from coverage_review import bundle, decode, read_file, require, sha, MAX_OUTPUT, MAX_REPORT

MAX_SELECTION = 64 * 1024


def quoted(name):
    require(isinstance(name, str) and '\x00' not in name, 'invalid identifier')
    return '"' + name.replace('"', '""') + '"'


def cell(value):
    """Preserve SQLite storage classes and integers beyond JSON's safe range."""
    if value is None: return {'type': 'null', 'value': None}
    if isinstance(value, bytes): return {'type': 'blob', 'value': base64.b64encode(value).decode('ascii')}
    if isinstance(value, str): return {'type': 'text', 'value': value}
    if isinstance(value, int): return {'type': 'integer', 'value': str(value)}
    require(isinstance(value, float) and math.isfinite(value), 'nonfinite SQLite real is unsupported')
    return {'type': 'real', 'value': repr(value)}


def parameter(value):
    require(isinstance(value, dict) and set(value) == {'type', 'value'}, 'filter value requires type and value')
    kind, data = value['type'], value['value']
    if kind == 'null':
        require(data is None, 'null filter value must be null')
        return None
    require(isinstance(data, str), 'non-null filter values must be strings')
    if kind == 'text': return data
    if kind == 'integer':
        require(re.fullmatch(r'0|-?[1-9][0-9]*', data) and len(data) <= 20, 'invalid integer filter')
        result = int(data)
        require(-(1 << 63) <= result < 1 << 63, 'integer filter outside signed 64-bit range')
        return result
    if kind == 'real':
        require(len(data) <= 64 and re.fullmatch(r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?', data), 'invalid real filter')
        result = float(data)
        require(math.isfinite(result), 'nonfinite real filter')
        return result
    if kind == 'blob':
        result = base64.b64decode(data, validate=True)
        require(base64.b64encode(result).decode('ascii') == data, 'blob filter requires canonical base64')
        return result
    raise ValueError('unsupported filter storage type')


@contextmanager
def database(data):
    require(sys.version_info >= (3, 11) and sqlite3.sqlite_version_info >= (3, 37, 0) and
            hasattr(sqlite3.Connection, 'deserialize'), 'requires Python 3.11+ and SQLite 3.37+ with deserialize support')
    require(len(data) <= MAX_REPORT and data.startswith(b'SQLite format 3\x00') and len(data) >= 100, 'selected artifact is not a bounded SQLite 3 database')
    require(data[18:20] == b'\x01\x01', 'requires a standalone rollback-journal database; WAL-mode files are unsupported')
    conn = sqlite3.connect(':memory:')
    try:
        conn.deserialize(data)
        # No artifact path is opened, no sidecar is discovered and no extraction occurs.
        conn.execute('PRAGMA query_only=ON')
        conn.execute('PRAGMA trusted_schema=OFF')
        conn.execute('PRAGMA temp_store=MEMORY')
        if hasattr(conn, 'enable_load_extension'): conn.enable_load_extension(False)
        for limit, maximum in [(sqlite3.SQLITE_LIMIT_LENGTH, MAX_REPORT),
                               (sqlite3.SQLITE_LIMIT_SQL_LENGTH, MAX_SELECTION),
                               (sqlite3.SQLITE_LIMIT_COLUMN, 256),
                               (sqlite3.SQLITE_LIMIT_ATTACHED, 0)]:
            conn.setlimit(limit, maximum)
        remaining = 5000

        def progress():
            nonlocal remaining
            remaining -= 1
            return int(remaining <= 0)

        conn.set_progress_handler(progress, 1000)

        def authorize(action, arg1, arg2, db, origin):
            if action == sqlite3.SQLITE_SELECT: return sqlite3.SQLITE_OK
            if action == sqlite3.SQLITE_READ and db == 'main' and origin is None: return sqlite3.SQLITE_OK
            if action == sqlite3.SQLITE_PRAGMA and arg1 in ('table_list', 'table_xinfo', 'foreign_key_list'): return sqlite3.SQLITE_OK
            if action == sqlite3.SQLITE_FUNCTION and arg2 == 'typeof': return sqlite3.SQLITE_OK
            return sqlite3.SQLITE_DENY

        conn.set_authorizer(authorize)
        yield conn
    finally:
        conn.close()


def folded(value):
    return value.translate(str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'))


def foreign_keys(conn, table):
    """Expose declarations, not a claim that referential constraints are valid."""
    grouped = {}
    for identity, sequence, parent, child, target, update, delete, match in conn.execute('PRAGMA main.foreign_key_list(' + quoted(table) + ')'):
        require(len(grouped) < 128 or identity in grouped, 'table exceeds 128 foreign keys')
        relation = grouped.setdefault(identity, {'id': identity, 'referenced_table': parent,
            'columns': [], 'referenced_columns': [], 'on_update': update, 'on_delete': delete, 'match': match})
        require(sequence == len(relation['columns']) and sequence < 128, 'unsupported foreign-key column sequence')
        relation['columns'].append(child)
        relation['referenced_columns'].append(target)
    return [grouped[key] for key in sorted(grouped)]


def inventory(conn):
    tables = []
    for db, name, kind, count, without_rowid, strict in conn.execute('PRAGMA main.table_list'):
        if db != 'main' or name.startswith('sqlite_'): continue
        require(len(tables) < 100, 'database exceeds 100 schema objects')
        require(count <= 128, 'schema object exceeds 128 columns')
        columns = []
        # Do not open virtual/shadow tables or evaluate views to discover their columns.
        if kind == 'table':
            for cid, column, declared, notnull, default, pk, hidden in conn.execute('PRAGMA main.table_xinfo(' + quoted(name) + ')'):
                columns.append({'name': column, 'declared_type': declared, 'not_null': bool(notnull),
                                'primary_key_position': pk, 'generated': hidden != 0})
        tables.append({'name': name, 'kind': kind, 'row_selection_supported': kind == 'table',
                       'without_rowid': bool(without_rowid), 'strict': bool(strict), 'columns': columns,
                       'foreign_keys': foreign_keys(conn, name) if kind == 'table' else []})
    tables.sort(key=lambda table: table['name'])
    for parent in tables:
        parent['incoming_foreign_keys'] = [relation | {'child_table': child['name']}
            for child in tables for relation in child['foreign_keys']
            if folded(relation['referenced_table']) == folded(parent['name'])]
    return tables


def selection_recipe(raw, tables):
    recipe = decode(raw)
    require(isinstance(recipe, dict) and set(recipe) <= {'table', 'columns', 'where', 'order_by'} and 'table' in recipe, 'selection requires table and optional columns, where, order_by')
    require(isinstance(recipe['table'], str), 'table must be an exact name')
    table = next((item for item in tables if item['name'] == recipe['table']), None)
    require(table is not None and table['row_selection_supported'], 'selection requires a listed ordinary table')
    available = {item['name']: item for item in table['columns'] if not item['generated']}
    columns = recipe.get('columns', list(available))
    require(isinstance(columns, list) and 1 <= len(columns) <= 128 and all(isinstance(name, str) and name in available for name in columns), 'columns must name stored columns in the selected table')
    require(len(set(columns)) == len(columns), 'duplicate selected column')
    filters = recipe.get('where', [])
    require(isinstance(filters, list) and len(filters) <= 8, 'where accepts at most 8 exact filters')
    for item in filters:
        require(isinstance(item, dict) and set(item) == {'column', 'value'} and isinstance(item['column'], str) and item['column'] in available, 'filter requires a stored column and typed value')
        parameter(item['value'])
    order = recipe.get('order_by', [])
    require(isinstance(order, list) and len(order) <= 8, 'order_by accepts at most 8 columns')
    seen = set()
    for item in order:
        require(isinstance(item, dict) and set(item) == {'column', 'direction'} and isinstance(item['column'], str) and item['column'] in available and item['direction'] in ('asc', 'desc'), 'order_by requires stored column and asc/desc direction')
        require(item['column'] not in seen, 'duplicate ordering column')
        seen.add(item['column'])
    if table['without_rowid']:
        locator = [item['name'] for item in sorted(table['columns'], key=lambda c: c['primary_key_position']) if item['primary_key_position']]
        require(locator and all(name in available for name in locator), 'unsupported primary-key locator')
        locator_kind = 'primary-key'
    else:
        # SQLite identifiers are ASCII case insensitive, even though recipe names are exact.
        names = {folded(item['name']) for item in table['columns']}
        locator = next(([name] for name in ('_rowid_', 'rowid', 'oid') if name not in names), None)
        require(locator is not None, 'all rowid aliases are shadowed; row browsing unsupported')
        locator_kind = 'rowid'
    normalized = {'table': table['name'], 'columns': columns, 'where': filters, 'order_by': order}
    return normalized, locator, locator_kind


def selected_rows(conn, recipe, locator, offset, limit, reference=None, incoming=None):
    filters, parameters = [], []
    if reference is not None:
        names, values = reference
        filters.extend(quoted(name) + ' = ?' for name in names)
        parameters.extend(values)
    if incoming is not None:
        parent, parent_columns, child_columns, anchor_columns, anchor_values = incoming
        predicates, anchor_parameters = anchor_filter(anchor_columns, anchor_values, 'parent.')
        # Unary + removes the child column's affinity. SQLite foreign-key lookup
        # applies only the parent affinity/collation, even with conflicting child types.
        predicates.extend('parent.' + quoted(left) + ' = +target.' + quoted(right)
                          for left, right in zip(parent_columns, child_columns))
        filters.append('EXISTS (SELECT 1 FROM main.' + quoted(parent) + ' AS parent WHERE ' + ' AND '.join(predicates) + ')')
        parameters.extend(anchor_parameters)
    for item in recipe['where']:
        name, value = quoted(item['column']), item['value']
        filters.append('(typeof(' + name + ') = ? AND ' + name + ' COLLATE BINARY IS ?)')
        parameters.extend([value['type'], parameter(value)])
    query = 'SELECT ' + ', '.join(quoted(name) for name in locator + recipe['columns']) + ' FROM main.' + quoted(recipe['table']) + ' AS target'
    if filters: query += ' WHERE ' + ' AND '.join(filters)
    order = [quoted(item['column']) + ' COLLATE BINARY ' + item['direction'].upper() for item in recipe['order_by']]
    order += [quoted(name) + ' COLLATE BINARY ASC' for name in locator]
    query += ' ORDER BY ' + ', '.join(order) + ' LIMIT ? OFFSET ?'
    result = []
    for values in conn.execute(query, [*parameters, limit + 1, offset]):
        result.append({'locator': [cell(value) for value in values[:len(locator)]],
                       'values': [cell(value) for value in values[len(locator):]]})
    return result[:limit], len(result) > limit


def resolve_relationship(relation, child, tables):
    def resolve(names, object_):
        available = {folded(column['name']): column['name'] for column in object_['columns'] if not column['generated']}
        require(all(isinstance(name, str) and folded(name) in available for name in names), 'foreign key requires stored source and target columns')
        return [available[folded(name)] for name in names]

    child_columns = resolve(relation['columns'], child)
    parent = next((item for item in tables if folded(item['name']) == folded(relation['referenced_table'])), None)
    require(parent is not None and parent['row_selection_supported'], 'foreign key target must be a listed ordinary table')
    declared = relation['referenced_columns']
    if all(name is None for name in declared):
        parent_columns = [column['name'] for column in sorted(parent['columns'], key=lambda column: column['primary_key_position']) if column['primary_key_position']]
        require(len(parent_columns) == len(child_columns), 'implicit foreign key requires a matching target primary key')
    else:
        parent_columns = declared
    return child_columns, parent, resolve(parent_columns, parent)


def anchor_filter(columns, typed_values, prefix=''):
    require(isinstance(typed_values, list) and len(typed_values) == len(columns), 'locator requires one typed value per source locator column')
    values = [parameter(value) for value in typed_values]
    require(all(value is not None for value in values), 'source locator must not contain NULL')
    predicates = ['(typeof(' + prefix + quoted(name) + ') = ? AND ' + prefix + quoted(name) + ' COLLATE BINARY IS ?)' for name in columns]
    parameters = [item for typed, value in zip(typed_values, values) for item in (typed['type'], value)]
    return predicates, parameters


def anchor_row(conn, table, columns, locator_columns, locator):
    predicates, parameters = anchor_filter(locator_columns, locator)
    query = 'SELECT ' + ', '.join(quoted(name) for name in columns) + ' FROM main.' + quoted(table) + ' WHERE ' + ' AND '.join(predicates) + ' LIMIT 2'
    anchors = conn.execute(query, parameters).fetchall()
    require(len(anchors) == 1, 'source locator must identify exactly one retained row')
    return anchors[0]


def referencing_rows(conn, raw, tables, offset, limit, database_sha256):
    request = decode(raw)
    required = {'table', 'locator', 'child_table', 'foreign_key', 'database_sha256'}
    require(isinstance(request, dict) and required <= set(request) <= required | {'columns', 'where', 'order_by'},
            'referencing selection requires database_sha256, table, locator, child_table, foreign_key and optional columns, where, order_by')
    require(request['database_sha256'] == database_sha256, 'referencing selection database fingerprint does not match retained artifact')
    anchor, anchor_columns, anchor_kind = selection_recipe(json.dumps({'table': request['table']}).encode(), tables)
    child_request = {'table': request['child_table']}
    for key in ('columns', 'where', 'order_by'):
        if key in request: child_request[key] = request[key]
    target, locator, kind = selection_recipe(json.dumps(child_request).encode(), tables)
    child = next(item for item in tables if item['name'] == target['table'])
    identity = request['foreign_key']
    require(type(identity) is int and identity >= 0, 'foreign_key must be a listed integer id')
    relation = next((item for item in child['foreign_keys'] if item['id'] == identity), None)
    require(relation is not None, 'foreign key is not declared by the selected child table')
    child_columns, parent, parent_columns = resolve_relationship(relation, child, tables)
    require(parent['name'] == anchor['table'], 'selected child foreign key does not reference the anchor table')
    key = anchor_row(conn, parent['name'], parent_columns, anchor_columns, request['locator'])
    if any(value is None for value in key):
        status, rows, more = 'null-parent-key', [], False
    else:
        incoming = (parent['name'], parent_columns, child_columns, anchor_columns, request['locator'])
        rows, more = selected_rows(conn, target, locator, offset, limit, incoming=incoming)
        found = rows
        if not found and offset:
            found, _ = selected_rows(conn, target, locator, 0, 1, incoming=incoming)
        status = 'matching-child-rows' if found else 'no-matching-child-rows'
    metadata = {'source_row': {'table': parent['name'], 'locator': {'kind': anchor_kind, 'columns': anchor_columns, 'values': request['locator']},
                               'reference_columns': parent_columns, 'reference_values': [cell(value) for value in key]},
                'relationship': relation | {'child_table': child['name'], 'resolved_child_columns': child_columns,
                                             'resolved_table': parent['name'], 'resolved_columns': parent_columns},
                'reference_status': status,
                'matching': 'Incoming rows use parent affinity and collation, followed by exact child filters. A declaration does not certify integrity, unique ownership or causal impact.'}
    return target, locator, kind, rows, more, metadata


def relation_rows(conn, raw, tables, offset, limit, database_sha256):
    request = decode(raw)
    require(isinstance(request, dict) and set(request) <= {'table', 'locator', 'foreign_key', 'database_sha256', 'columns', 'order_by'} and
            {'table', 'locator', 'foreign_key', 'database_sha256'} <= set(request), 'related selection requires database_sha256, table, locator, foreign_key and optional columns, order_by')
    require(request['database_sha256'] == database_sha256, 'related selection database fingerprint does not match retained artifact')
    source_recipe, source_locator, source_kind = selection_recipe(json.dumps({'table': request['table']}).encode(), tables)
    table = next(item for item in tables if item['name'] == source_recipe['table'])
    identity = request['foreign_key']
    require(type(identity) is int and identity >= 0, 'foreign_key must be a listed integer id')
    relation = next((item for item in table['foreign_keys'] if item['id'] == identity), None)
    require(relation is not None, 'foreign key is not declared by the selected table')
    locator = request['locator']
    source_columns, parent, parent_columns = resolve_relationship(relation, table, tables)
    target_request = {'table': parent['name']}
    for key in ('columns', 'order_by'):
        if key in request: target_request[key] = request[key]
    target, target_locator, target_kind = selection_recipe(json.dumps(target_request).encode(), tables)

    key = anchor_row(conn, table['name'], source_columns, source_locator, locator)
    if any(value is None for value in key):
        status, rows, more = 'null-reference', [], False
    else:
        # Parent columns on the left preserve their declared affinity and collation,
        # as required by SQLite foreign-key parent lookup. No user SQL is accepted.
        condition = ' AND '.join(quoted(name) + ' = ?' for name in parent_columns)
        found = conn.execute('SELECT 1 FROM main.' + quoted(parent['name']) + ' WHERE ' + condition + ' LIMIT 1', key).fetchone()
        status = 'matching-parent-rows' if found is not None else 'no-matching-parent'
        rows, more = selected_rows(conn, target, target_locator, offset, limit, (parent_columns, key))
    metadata = {'source_row': {'table': table['name'], 'locator': {'kind': source_kind, 'columns': source_locator, 'values': locator},
                               'reference_columns': source_columns, 'reference_values': [cell(value) for value in key]},
                'relationship': relation | {'resolved_table': parent['name'], 'resolved_columns': parent_columns},
                'reference_status': status,
                'matching': 'Parent column affinity and declared collation; all matching parent rows are retained. Declaration validity and uniqueness are not certified.'}
    return target, target_locator, target_kind, rows, more, metadata


def csv_output(columns, rows):
    stream = io.StringIO(newline='')
    writer = csv.writer(stream, quoting=csv.QUOTE_ALL, lineterminator='\r\n')
    writer.writerow(['locator_json'] + ['column:' + name for name in columns])
    for row in rows:
        writer.writerow([json.dumps(row['locator'], ensure_ascii=False)] +
                        [json.dumps(value, ensure_ascii=False) for value in row['values']])
    return stream.getvalue()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle'); parser.add_argument('--database', required=True, help='exact retained database artifact path')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('schema', help='list schema objects and stored column metadata as JSON')
    for command, help_text in [('rows', 'select ordinary table rows with a local JSON selection'),
                               ('related', 'follow one retained row through a declared outgoing foreign key'),
                               ('referencing', 'inspect child records that reference one retained parent row')]:
        rows = commands.add_parser(command, help=help_text)
        rows.add_argument('--selection', required=True)
        rows.add_argument('--offset', type=int, default=0); rows.add_argument('--limit', type=int, default=100)
        rows.add_argument('--format', choices=('json', 'csv'), default='json')
    comparison = commands.add_parser('compare', help='compare two retained table snapshots by explicit typed key columns')
    comparison.add_argument('after_bundle')
    comparison.add_argument('--after-database', help='after artifact path; defaults to --database')
    comparison.add_argument('--selection', required=True)
    comparison.add_argument('--format', choices=('json', 'csv'), default='json')
    args = parser.parse_args(argv)
    try:
        if args.command in ('rows', 'related', 'referencing'):
            require(0 <= args.offset <= 1000000 and 1 <= args.limit <= 1000, 'offset must be 0..1000000 and limit 1..1000')
        data, source = bundle(args.bundle, args.database, report_label='SQLite database')
        if args.command == 'compare':
            from sqlite_compare import comparison_output
            context, output = comparison_output(args, data, source)
        else:
            context = {'schema': 'moonfort.sqlite-review.v1', 'source': source, 'operation': args.command,
                       'sqlite_version': sqlite3.sqlite_version,
                       'meaning': 'Read-only exploration of a supplied retained database copy; not authenticity, live state, execution, acceptance or promotion.'}
            with database(data) as conn:
                tables = inventory(conn)
                if args.command == 'schema':
                    context['object_count'] = len(tables)
                    output = json.dumps(context | {'objects': tables}, ensure_ascii=False, indent=2) + '\n'
                else:
                    raw = read_file(args.selection, MAX_SELECTION)
                    if args.command in ('related', 'referencing'):
                        review = relation_rows if args.command == 'related' else referencing_rows
                        recipe, locator, kind, result, more, relationship = review(conn, raw, tables, args.offset, args.limit, sha(data))
                        context.update(relationship)
                        context['relation_selection'] = decode(raw)
                    else:
                        recipe, locator, kind = selection_recipe(raw, tables)
                        result, more = selected_rows(conn, recipe, locator, args.offset, args.limit)
                    context.update(selection_sha256=sha(raw), selection_size_bytes=len(raw), selection=recipe,
                                   locator={'kind': kind, 'columns': locator}, offset=args.offset, limit=args.limit,
                                   row_count=len(result), has_more=more, next_offset=args.offset + len(result) if more else None,
                                   ordering='Explicit columns then unique locator; BINARY collation, ascending locator ties.')
                    output = csv_output(recipe['columns'], result) if args.format == 'csv' else json.dumps(context | {'rows': result}, ensure_ascii=False, indent=2) + '\n'
        encoded = output.encode('utf-8')
        require(len(encoded) <= MAX_OUTPUT, 'selection exceeds 16 MiB output bound')
        sys.stdout.buffer.write(encoded)
        sys.stderr.write(json.dumps(context | {'candidate_sha256': sha(encoded), 'candidate_size_bytes': len(encoded)}, ensure_ascii=False, indent=2) + '\n')
        return 0
    except (ValueError, OSError, UnicodeError, TypeError, KeyError, RecursionError, zipfile.BadZipFile, NotImplementedError, sqlite3.Error) as error:
        print('SQLite review refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__': sys.exit(main())
