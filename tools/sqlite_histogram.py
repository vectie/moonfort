"""Bounded numeric bands over original retained SQLite rows."""
import bisect
import json
from fractions import Fraction
from coverage_review import decode, read_file, require, sha
from sqlite_review import MAX_SELECTION, database, inventory, parameter, selection_recipe
from sqlite_summary import compact, scan


def distribution(conn, raw, fingerprint):
    request = decode(raw)
    required = {'database_sha256', 'table', 'column', 'boundaries'}
    require(isinstance(request, dict) and required <= set(request) <= required | {'where'},
            'histogram requires database_sha256, table, column, boundaries and optional where')
    require(request['database_sha256'] == fingerprint, 'database fingerprint differs')
    edges = request['boundaries']
    require(isinstance(edges, list) and 1 <= len(edges) <= 32, 'supply 1..32 numeric boundaries')
    numeric = []
    for edge in edges:
        value = parameter(edge)
        require(edge['type'] in ('integer', 'real'), 'boundaries must be typed numbers')
        numeric.append(Fraction(value))
    require(all(a < b for a, b in zip(numeric, numeric[1:])), 'boundaries must be strictly increasing')
    selection, locator, kind = selection_recipe(compact({'table': request['table'],
        'columns': [request['column']], 'where': request.get('where', [])}).encode(), inventory(conn))
    selection, locator, kind = selection_recipe(compact({'table': request['table'],
        'where': request.get('where', [])}).encode(), inventory(conn))
    position = selection['columns'].index(request['column'])
    bands = [{'index': i, 'lower_inclusive': edges[i-1] if i else None,
              'upper_exclusive': edges[i] if i < len(edges) else None,
              'count': 0, 'rows': []} for i in range(len(edges)+1)]
    excluded = {key: {'count': 0, 'rows': []} for key in ('null', 'text', 'blob')}
    count = 0
    for row, values in scan(conn, selection, locator):
        value = values[position]
        typed = row['values'][position]
        if typed['type'] in ('integer', 'real'):
            group = bands[bisect.bisect_right(numeric, Fraction(value))]
        else:
            group = excluded[typed['type']]
        group['count'] += 1
        group['rows'].append({'locator': row['locator'], 'value': typed, 'values': row['values']})
        count += 1
    return {'selection': request, 'columns': selection['columns'], 'locator': {'kind': kind, 'columns': locator},
            'selected_row_count': count, 'bands': bands, 'excluded': excluded,
            'complete_selection_scanned': True}


def histogram_output(args, data, source):
    raw = read_file(args.selection, MAX_SELECTION)
    with database(data) as conn:
        result = distribution(conn, raw, sha(data))
    context = {'schema': 'moonfort.sqlite-histogram.v1', 'operation': 'histogram',
               'source': source, 'selection_sha256': sha(raw),
               'meaning': 'Read-only retained-copy exploration, not execution or approval.',
               'numeric_semantics': 'Exact rational comparison of stored integers and IEEE binary reals. Lower bounds inclusive, upper bounds exclusive; tails unbounded. Text, NULL and BLOB never coerced.',
               'limits': 'Complete selection up to 10000 rows and 16 MiB projection; exceeding a bound refuses the whole result.'}
    return context, json.dumps(context | result, ensure_ascii=False, indent=2)+'\n'
