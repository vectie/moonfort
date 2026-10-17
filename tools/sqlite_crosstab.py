"""Explore the intersection of two exact typed categories in retained rows."""
import json
from coverage_review import decode, read_file, require, sha
from sqlite_review import MAX_SELECTION, database, inventory, selection_recipe
from sqlite_summary import compact, scan


def crosstab(conn, raw, fingerprint):
    request = decode(raw)
    required = {'database_sha256', 'table', 'row_column', 'column_column'}
    require(isinstance(request, dict) and required <= set(request) <= required | {'where'},
            'crosstab requires database_sha256, table, row_column, column_column and optional where')
    require(request['database_sha256'] == fingerprint, 'database fingerprint differs')
    require(isinstance(request['row_column'], str) and isinstance(request['column_column'], str)
            and request['row_column'] != request['column_column'], 'choose two distinct stored columns')
    # Validate axes, then retain every stored value for direct cell-member inspection.
    selection_recipe(compact({'table': request['table'], 'columns': [request['row_column'],
        request['column_column']], 'where': request.get('where', [])}).encode(), inventory(conn))
    selection, locator, kind = selection_recipe(compact({'table': request['table'],
        'where': request.get('where', [])}).encode(), inventory(conn))
    row_pos = selection['columns'].index(request['row_column'])
    col_pos = selection['columns'].index(request['column_column'])
    row_keys, col_keys, members = {}, {}, {}
    total = 0
    for row, _ in scan(conn, selection, locator):
        r, c = row['values'][row_pos], row['values'][col_pos]
        rk, ck = compact(r), compact(c)
        row_keys[rk], col_keys[ck] = r, c
        require(len(row_keys) <= 64 and len(col_keys) <= 64,
                'crosstab supports at most 64 exact categories per axis')
        members.setdefault((rk, ck), []).append(row)
        total += 1
    rows, columns = sorted(row_keys), sorted(col_keys)
    counts = [[len(members.get((r, c), [])) for c in columns] for r in rows]
    return {'selection': request, 'row_keys': [row_keys[r] for r in rows],
            'column_keys': [col_keys[c] for c in columns], 'counts': counts,
            'row_totals': [sum(values) for values in counts],
            'column_totals': [sum(values[i] for values in counts) for i in range(len(columns))],
            'selected_row_count': total, 'columns': selection['columns'],
            'locator': {'kind': kind, 'columns': locator},
            'cells': [{'row_index': i, 'column_index': j, 'rows': members[(r,c)]}
                      for i,r in enumerate(rows) for j,c in enumerate(columns) if (r,c) in members],
            'complete_selection_scanned': True}


def crosstab_output(args, data, source):
    raw = read_file(args.selection, MAX_SELECTION)
    with database(data) as conn:
        result = crosstab(conn, raw, sha(data))
    context = {'schema': 'moonfort.sqlite-crosstab.v1', 'operation': 'crosstab',
               'source': source, 'selection_sha256': sha(raw),
               'meaning': 'Read-only exploration of a retained copy, not execution or approval.',
               'matching': 'Exact typed category values; NULL, text, BLOB, integer and real remain distinct. Axes ordered by compact typed JSON. All zero intersections included in counts.',
               'limits': 'At most 64 categories per axis, 10000 rows and 16 MiB projection/output; exceeding a bound refuses the result.'}
    return context, json.dumps(context | result, ensure_ascii=False, indent=2)+'\n'
