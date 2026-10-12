"""Typed-key comparison for the retained SQLite review command, not a SQL interface."""
import csv
import io
import json
import sqlite3
from coverage_review import bundle, decode, read_file, require, sha, MAX_OUTPUT
from sqlite_review import MAX_SELECTION, cell, database, inventory, quoted, selection_recipe

MAX_ROWS = 10000
MAX_SCAN_BYTES = 16 * 1024 * 1024


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def comparison_recipe(raw):
    request = decode(raw)
    required = {'before_database_sha256', 'after_database_sha256', 'table', 'key_columns'}
    require(isinstance(request, dict) and required <= set(request) <= required | {'columns'},
            'comparison requires before_database_sha256, after_database_sha256, table, key_columns and optional columns')
    keys = request['key_columns']
    require(isinstance(keys, list) and 1 <= len(keys) <= 8 and all(isinstance(name, str) for name in keys)
            and len(set(keys)) == len(keys), 'key_columns requires 1..8 distinct stored column names')
    return request


def scan(data, source, request, side):
    """Read the complete bounded projection; never compare only the first page."""
    require(request[side + '_database_sha256'] == sha(data), side + ' database fingerprint does not match retained artifact')
    recipe = {'table': request['table']}
    if 'columns' in request: recipe['columns'] = request['columns']
    with database(data) as conn:
        normalized, locator, kind = selection_recipe(compact(recipe).encode('utf-8'), inventory(conn))
        columns = normalized['columns']
        require(all(name in columns for name in request['key_columns']), 'key columns must be included in the compared columns')
        positions = [columns.index(name) for name in request['key_columns']]
        query = ('SELECT ' + ', '.join(quoted(name) for name in locator + columns) + ' FROM main.' + quoted(normalized['table'])
                 + ' ORDER BY ' + ', '.join(quoted(name) + ' COLLATE BINARY ASC' for name in locator) + ' LIMIT ?')
        indexed, scanned_bytes = {}, 0
        for number, values in enumerate(conn.execute(query, [MAX_ROWS + 1]), 1):
            require(number <= MAX_ROWS, side + ' selection exceeds 10000 rows; no partial comparison produced')
            row = {'locator': [cell(value) for value in values[:len(locator)]],
                   'values': [cell(value) for value in values[len(locator):]]}
            key = [row['values'][position] for position in positions]
            require(all(value['type'] != 'null' for value in key), side + ' key contains NULL at locator ' + compact(row['locator']))
            token = compact(key)
            require(token not in indexed, side + ' duplicate typed key at locators ' +
                    compact(indexed[token]['locator'] if token in indexed else []) + ' and ' + compact(row['locator']))
            scanned_bytes += len(compact(row).encode('utf-8')) + len(token.encode('utf-8'))
            require(scanned_bytes <= MAX_SCAN_BYTES, side + ' comparison projection exceeds 16 MiB scan bound')
            indexed[token] = row
    return {'source': source, 'selection': normalized, 'locator': {'kind': kind, 'columns': locator},
            'row_count': len(indexed)}, indexed


def csv_output(changes):
    stream = io.StringIO(newline='')
    writer = csv.writer(stream, quoting=csv.QUOTE_ALL, lineterminator='\r\n')
    writer.writerow(['change', 'key_json', 'changed_columns_json', 'before_locator_json',
                     'after_locator_json', 'before_values_json', 'after_values_json'])
    for entry in changes:
        before, after = entry.get('before'), entry.get('after')
        writer.writerow([entry['change'], compact(entry['key']), compact(entry['changed_columns']),
                         compact(before['locator'] if before is not None else None),
                         compact(after['locator'] if after is not None else None),
                         compact(before['values'] if before is not None else None),
                         compact(after['values'] if after is not None else None)])
    return stream.getvalue()


def comparison_output(args, before_data, before_source):
    raw = read_file(args.selection, MAX_SELECTION)
    request = comparison_recipe(raw)
    after_data, after_source = bundle(args.after_bundle, args.after_database or args.database, report_label='SQLite database')
    before, before_rows = scan(before_data, before_source, request, 'before')
    after, after_rows = scan(after_data, after_source, request, 'after')
    columns = before['selection']['columns']
    require(columns == after['selection']['columns'],
            'stored columns differ; inspect schemas and choose an explicit shared columns projection')
    counts = {'before_rows': len(before_rows), 'after_rows': len(after_rows), 'added': 0, 'removed': 0, 'changed': 0, 'unchanged': 0}
    changes, output_bytes = [], 0
    for token in sorted(before_rows.keys() | after_rows.keys()):
        left, right = before_rows.get(token), after_rows.get(token)
        if left is not None and right is not None and left['values'] == right['values']:
            counts['unchanged'] += 1
            continue
        change = 'added' if left is None else 'removed' if right is None else 'changed'
        differing = columns if left is None or right is None else [name for name, old, new in zip(columns, left['values'], right['values']) if old != new]
        entry = {'change': change, 'key': json.loads(token), 'changed_columns': differing}
        if left is not None: entry['before'] = left
        if right is not None: entry['after'] = right
        output_bytes += len(compact(entry).encode('utf-8'))
        require(output_bytes <= MAX_OUTPUT, 'comparison exceeds 16 MiB output bound')
        changes.append(entry)
        counts[change] += 1
    context = {'schema': 'moonfort.sqlite-comparison.v1', 'operation': 'compare', 'sqlite_version': sqlite3.sqlite_version,
               'before': before, 'after': after, 'comparison_selection': request, 'selection_sha256': sha(raw),
               'selection_size_bytes': len(raw), 'key_columns': request['key_columns'], 'columns': columns,
               'counts': counts, 'complete': True,
               'ordering': 'Lexical order of compact JSON typed key arrays, not numeric or database collation order.',
               'matching': 'Exact storage class and typed serialized value; no affinity, collation, tolerance or inferred key mapping. Row locators are for drillback only.',
               'meaning': 'Complete bounded comparison of selected stored values in two supplied copies; not schema equivalence, authenticity, causal regression, execution, acceptance or promotion.'}
    output = csv_output(changes) if args.format == 'csv' else json.dumps(context | {'changes': changes}, ensure_ascii=False, indent=2) + '\n'
    return context, output
