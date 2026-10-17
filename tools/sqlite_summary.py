"""Exact grouped exploration of retained SQLite values, with paged member review."""
import csv
import io
import json
import sqlite3
from decimal import Decimal, localcontext
from fractions import Fraction

from coverage_review import decode, read_file, require, sha, MAX_OUTPUT
from sqlite_review import (MAX_SELECTION, cell, database, inventory, parameter,
                           quoted, selection_recipe, filter_predicates, csv_output as rows_csv)

MAX_ROWS = 10000
MAX_SCAN_BYTES = 16 * 1024 * 1024


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def summary_recipe(raw, tables, fingerprint, members=False):
    request = decode(raw)
    required = {'database_sha256', 'table', 'group_by', 'measures'}
    require(isinstance(request, dict) and required <= set(request) <= required | {'where'},
            'summary requires database_sha256, table, group_by, measures and optional where')
    require(request['database_sha256'] == fingerprint,
            'database fingerprint does not match retained artifact')
    for name, maximum, minimum in [('group_by', 8, 0), ('measures', 8, 0)]:
        values = request[name]
        require(isinstance(values, list) and minimum <= len(values) <= maximum and
                all(isinstance(item, str) for item in values) and len(set(values)) == len(values),
                name + ' requires 0..8 distinct stored column names')
    columns = list(dict.fromkeys(request['group_by'] + request['measures']))
    selection = {'table': request['table'], 'where': request.get('where', [])}
    if columns: selection['columns'] = columns
    normalized, locator, kind = selection_recipe(compact(selection).encode('utf-8'), tables)
    # Empty grouping/measure lists still allow a complete row-count survey. A
    # single stored column is read rather than silently removing row identity.
    if not columns: normalized['columns'] = normalized['columns'][:1]
    if members:
        normalized, locator, kind = selection_recipe(compact({
            'table': request['table'], 'where': request.get('where', [])
        }).encode('utf-8'), tables)
    return request, normalized, locator, kind


def scan(conn, selection, locator):
    """A complete, bounded projection; no aggregate is computed from a page."""
    query = ('SELECT ' + ', '.join(quoted(name) for name in locator + selection['columns']) +
             ' FROM main.' + quoted(selection['table']))
    filters, parameters = filter_predicates(selection['where'])
    if filters: query += ' WHERE ' + ' AND '.join(filters)
    query += ' ORDER BY ' + ', '.join(quoted(name) + ' COLLATE BINARY ASC' for name in locator) + ' LIMIT ?'
    scanned = 0
    for count, values in enumerate(conn.execute(query, parameters + [MAX_ROWS + 1]), 1):
        require(count <= MAX_ROWS, 'selection exceeds 10000 rows; no partial result produced')
        row = {'locator': [cell(value) for value in values[:len(locator)]],
               'values': [cell(value) for value in values[len(locator):]]}
        scanned += len(compact(row).encode('utf-8'))
        require(scanned <= MAX_SCAN_BYTES, 'selection projection exceeds 16 MiB scan bound')
        yield row, values[len(locator):]


def rational(value):
    if value is None: return None
    with localcontext() as context:
        context.prec = 17
        display = str(Decimal(value.numerator) / Decimal(value.denominator))
    return {'numerator': str(value.numerator), 'denominator': str(value.denominator),
            'decimal_approximation': display}


class Measure:
    def __init__(self):
        self.counts = dict.fromkeys(('null', 'integer', 'real', 'text', 'blob'), 0)
        self.total = Fraction(0)
        self.minimum = self.maximum = None

    def add(self, value, typed, locator):
        kind = typed['type']
        self.counts[kind] += 1
        if kind not in ('integer', 'real'): return
        exact = Fraction(value)
        self.total += exact
        # Equal numeric extrema retain the first source locator, even when the
        # original storage classes differ. The exact typed evidence is retained.
        if self.minimum is None or exact < self.minimum[0]: self.minimum = (exact, typed, locator)
        if self.maximum is None or exact > self.maximum[0]: self.maximum = (exact, typed, locator)

    def output(self):
        count = self.counts['integer'] + self.counts['real']
        def extreme(value):
            return None if value is None else {'value': value[1], 'locator': value[2]}
        return {'storage_counts': self.counts, 'numeric_count': count,
                'sum': rational(self.total) if count else None,
                'mean': rational(self.total / count) if count else None,
                'minimum': extreme(self.minimum), 'maximum': extreme(self.maximum)}


def groups(conn, request, selection, locator):
    positions = [selection['columns'].index(name) for name in request['group_by']]
    measures = [selection['columns'].index(name) for name in request['measures']]
    indexed, row_count = {}, 0
    for row, values in scan(conn, selection, locator):
        key = [row['values'][position] for position in positions]
        token = compact(key)
        if token not in indexed:
            indexed[token] = {'key': key, 'row_count': 0, 'locators': [],
                              'measures': [Measure() for _ in measures]}
        group = indexed[token]
        group['row_count'] += 1
        row_count += 1
        group['locators'].append(row['locator'])
        for measure, position in zip(group['measures'], measures):
            measure.add(values[position], row['values'][position], row['locator'])
    result, output_bytes = [], 0
    for token in sorted(indexed, key=lambda key: (-indexed[key]['row_count'], key)):
        group = indexed[token]
        group['measures'] = {name: measure.output() for name, measure in zip(request['measures'], group['measures'])}
        output_bytes += len(compact(group).encode('utf-8'))
        require(output_bytes <= MAX_OUTPUT, 'summary exceeds 16 MiB output bound')
        result.append(group)
    return result, row_count


def summary_csv(groups):
    stream = io.StringIO(newline='')
    writer = csv.writer(stream, quoting=csv.QUOTE_ALL, lineterminator='\r\n')
    writer.writerow(['key_json', 'row_count', 'measures_json', 'locators_json'])
    for group in groups:
        writer.writerow([compact(group['key']), group['row_count'], compact(group['measures']), compact(group['locators'])])
    return stream.getvalue()


def group_key(raw, width):
    key = decode(raw)
    require(isinstance(key, list) and len(key) == width, 'group key requires one typed cell per group_by column')
    for typed in key:
        value = parameter(typed)
        require(cell(value) == typed, 'group key must use the exact canonical typed cells from summary output')
    return key


def summary_output(args, data, source):
    raw = read_file(args.selection, MAX_SELECTION)
    members = args.command == 'group-rows'
    context = {'schema': 'moonfort.sqlite-summary.v1', 'operation': args.command,
               'source': source, 'sqlite_version': sqlite3.sqlite_version,
               'selection_sha256': sha(raw), 'selection_size_bytes': len(raw),
               'matching': 'Exact typed serialized group values; no affinity, collation or numeric coercion. Filters use the existing typed BINARY row-selection semantics.',
               'numeric_semantics': 'Only integer and finite real storage classes contribute. Sum and mean are exact rational values of stored integers/IEEE binary reals; decimal_approximation is rounded to 17 significant digits. NULL, text and BLOB counts are explicit.',
               'meaning': 'Bounded exploration of a supplied retained copy; not authenticity, producer completeness, live state, execution, acceptance or promotion.'}
    with database(data) as conn:
        request, selection, locator, kind = summary_recipe(raw, inventory(conn), sha(data), members)
        context.update(summary_selection=request, selection=selection,
                       locator={'kind': kind, 'columns': locator}, group_by=request['group_by'],
                       measure_columns=request['measures'])
        if members:
            key_raw = read_file(args.group, MAX_SELECTION)
            key = group_key(key_raw, len(request['group_by']))
            positions = [selection['columns'].index(name) for name in request['group_by']]
            token, rows, total, scanned = compact(key), [], 0, 0
            for row, _ in scan(conn, selection, locator):
                scanned += 1
                if compact([row['values'][position] for position in positions]) != token: continue
                if args.offset <= total < args.offset + args.limit: rows.append(row)
                total += 1
            more = args.offset + len(rows) < total
            context.update(group_key=key, group_key_sha256=sha(key_raw), group_key_size_bytes=len(key_raw),
                           selected_row_count=scanned, total_group_rows=total,
                           offset=args.offset, limit=args.limit, row_count=len(rows), has_more=more,
                           next_offset=args.offset + len(rows) if more else None,
                           complete_selection_scanned=True,
                           ordering='Unique source locator in BINARY ascending order.')
            output = rows_csv(selection['columns'], rows) if args.format == 'csv' else json.dumps(context | {'rows': rows}, ensure_ascii=False, indent=2) + '\n'
        else:
            result, count = groups(conn, request, selection, locator)
            context.update(selected_row_count=count, group_count=len(result), complete=True,
                           ordering='Descending row count, then lexical compact JSON typed key array; source locators in BINARY ascending order.')
            output = summary_csv(result) if args.format == 'csv' else json.dumps(context | {'groups': result}, ensure_ascii=False, indent=2) + '\n'
    require(len(output.encode('utf-8')) <= MAX_OUTPUT, 'summary exceeds 16 MiB output bound')
    return context, output
