"""Bounded schema metadata comparison and existing-CLI row navigation."""
import json
import sqlite3
from coverage_review import bundle, decode, read_file, require, sha
from sqlite_review import MAX_SELECTION, database, inventory, selection_recipe

FIELDS = ('kind', 'without_rowid', 'strict', 'columns', 'foreign_keys')


def snapshot(data, expected, side):
    require(expected == sha(data), side + ' database fingerprint does not match retained artifact')
    with database(data) as conn:
        return inventory(conn)


def navigation(table, tables, source):
    if table is None:
        return {'available': False, 'reason': 'object absent on this side'}
    try:
        recipe, locator, kind = selection_recipe(json.dumps({'table': table['name']}).encode(), tables)
        require(len(json.dumps(recipe, ensure_ascii=False, separators=(',', ':')).encode('utf-8')) <= MAX_SELECTION,
                'default row selection exceeds 64 KiB; choose a smaller stored-column projection manually')
    except ValueError as error:
        return {'available': False, 'reason': str(error)}
    fingerprint = source['source_file']['fingerprint']
    return {'available': True, 'selection': recipe,
            'locator': {'kind': kind, 'columns': locator},
            'database_sha256': fingerprint, 'bundle_sha256': source['bundle_sha256'],
            'argv_after_bundle': ['--database', source['source_file']['relative_path'], 'rows',
                                  '--selection', '<saved-selection.json>',
                                  '--expected-database-sha256', fingerprint, '--offset', '0', '--limit', '100'],
            'instruction': 'Save selection as compact UTF-8 JSON and replace the placeholder with its path. Supply this side\'s retained ZIP before these arguments. Use next_offset to continue; locators apply only to this database.'}


def column_changes(before, after):
    left = {column['name']: (position, column) for position, column in enumerate(before or [])}
    right = {column['name']: (position, column) for position, column in enumerate(after or [])}
    changes = []
    for name in sorted(left.keys() | right.keys()):
        old, new = left.get(name), right.get(name)
        if old == new:
            continue
        entry = {'name': name, 'change': 'added' if old is None else 'removed' if new is None else 'changed'}
        for side, value in [('before', old), ('after', new)]:
            if value is not None:
                entry[side] = {'position': value[0], 'column': value[1]}
        changes.append(entry)
    return changes


def schema_comparison_output(args, before_data, before_source):
    raw = read_file(args.selection, MAX_SELECTION)
    request = decode(raw)
    required = {'before_database_sha256', 'after_database_sha256'}
    require(isinstance(request, dict) and required <= set(request) <= required | {'table'},
            'schema comparison requires before_database_sha256, after_database_sha256 and optional table')
    require('table' not in request or isinstance(request['table'], str), 'table must be an exact object name')
    after_data, after_source = bundle(args.after_bundle, args.after_database or args.database, report_label='SQLite database')
    before_tables = snapshot(before_data, request['before_database_sha256'], 'before')
    after_tables = snapshot(after_data, request['after_database_sha256'], 'after')
    before = {table['name']: table for table in before_tables}
    after = {table['name']: table for table in after_tables}
    entries, counts = [], dict.fromkeys(('added', 'removed', 'changed', 'unchanged'), 0)
    for name in sorted(before.keys() | after.keys()):
        left, right = before.get(name), after.get(name)
        changed = list(FIELDS) if left is None or right is None else [field for field in FIELDS if left[field] != right[field]]
        status = 'added' if left is None else 'removed' if right is None else 'changed' if changed else 'unchanged'
        entries.append({'name': name, 'change': status, 'changed_fields': changed,
                        'before_kind': left['kind'] if left else None, 'after_kind': right['kind'] if right else None})
        counts[status] += 1
    context = {'schema': 'moonfort.sqlite-schema-comparison.v1', 'operation': 'compare-schema',
               'sqlite_version': sqlite3.sqlite_version,
               'before': {'source': before_source, 'object_count': len(before)},
               'after': {'source': after_source, 'object_count': len(after)},
               'comparison_selection': request, 'selection_sha256': sha(raw), 'selection_size_bytes': len(raw),
               'counts': counts, 'complete_metadata_inventory': True, 'compared_fields': list(FIELDS),
               'matching': 'Exact case-sensitive object and column names, ordered columns and foreign-key declarations including local IDs; no rename inference or SQL semantic equivalence.',
               'limits': ['Ordinary table column defaults are unevaluated SQL text; generated kind is reported, expression text is not compared.',
                          'Indexes, triggers, CHECK expressions, collations, CREATE SQL and view/virtual/shadow definitions are not compared. Unchanged means only equal listed metadata.',
                          'Incoming foreign keys are shown for navigation context, not compared as changes to the parent table. Declarations do not certify integrity.',
                          'No rows are compared by this command. Row navigation is paged and does not match records across revisions.'],
               'meaning': 'Read-only metadata inspection of supplied retained copies; not authenticity, live state, execution, acceptance, promotion or schema equivalence.'}
    result = context | {'objects': entries}
    if 'table' in request:
        name = request['table']
        require(name in before or name in after, 'selected table is absent from both retained inventories')
        left, right = before.get(name), after.get(name)
        result['selected'] = {'name': name, 'change': next(entry['change'] for entry in entries if entry['name'] == name),
                              'before': left, 'after': right,
                              'column_changes': column_changes(left['columns'] if left else [], right['columns'] if right else []),
                              'row_navigation': {'before': navigation(left, before_tables, before_source),
                                                 'after': navigation(right, after_tables, after_source)}}
    return context, json.dumps(result, ensure_ascii=False, indent=2) + '\n'
