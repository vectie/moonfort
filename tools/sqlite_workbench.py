#!/usr/bin/env python3
"""Loopback-only review of one pinned retained SQLite ZIP; no execution authority."""
import argparse
import json
from pathlib import Path
import secrets
import sqlite3
from http.server import BaseHTTPRequestHandler, HTTPServer
from types import SimpleNamespace
from sqlite_review import (bundle, database, inventory, selection_recipe, selected_rows,
    relation_rows, referencing_rows, query_output, require, sha, MAX_SELECTION, MAX_OUTPUT)

from sqlite_crosstab import crosstab
from sqlite_histogram import distribution

ASSETS = Path(__file__).with_name('sqlite_workbench')


def encoded(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False).encode('utf-8')


class Workbench:
    def __init__(self, archive, artifact):
        # The archive is verified once, then only these immutable bytes are used.
        self.data, self.source = bundle(archive, artifact, report_label='SQLite database')
        self.digest = sha(self.data)
        self.session = secrets.token_urlsafe(32)
        self.token = secrets.token_urlsafe(32)
        with database(self.data) as conn:
            self.tables = inventory(conn)

    def dispatch(self, request):
        require(isinstance(request, dict), 'request must be an object')
        require(request.get('session') == self.session and request.get('database_sha256') == self.digest,
                'stale session or database fingerprint')
        operation = request.get('operation')
        common = {'session', 'database_sha256', 'operation'}
        require(operation in ('schema', 'rows', 'related', 'referencing', 'query', 'crosstab', 'histogram'), 'unknown operation')
        allowed = common | ({'sql', 'parameters', 'max_rows'} if operation == 'query' else
                            {'selection'} if operation in ('crosstab', 'histogram') else
                            {'selection', 'offset', 'limit'} if operation != 'schema' else set())
        require(set(request) <= allowed, 'unexpected request field')
        context = {'session': self.session, 'database_sha256': self.digest, 'source': self.source,
                   'operation': operation, 'meaning': 'Retained copy review only; not authenticity, execution, acceptance or promotion.'}
        if operation == 'schema':
            return context | {'objects': self.tables}
        if operation == 'query':
            require(isinstance(request.get('sql'), str), 'SQL must be text')
            _, output = query_output(SimpleNamespace(max_rows=request.get('max_rows', 1000), format='json'),
                self.data, self.source, sql_bytes=request['sql'].encode('utf-8'),
                parameter_bytes=encoded({'database_sha256': self.digest, 'parameters': request.get('parameters', [])}))
            return json.loads(output) | {'session': self.session}
        if operation in ('crosstab', 'histogram'):
            raw = encoded(request.get('selection'))
            require(len(raw) <= MAX_SELECTION, 'selection exceeds 64 KiB')
            with database(self.data) as conn:
                explore = crosstab if operation == 'crosstab' else distribution
                return context | explore(conn, raw, self.digest)
        offset, limit = request.get('offset', 0), request.get('limit', 100)
        require(type(offset) is int and 0 <= offset <= 1000000 and type(limit) is int and 1 <= limit <= 1000,
                'offset must be 0..1000000 and limit 1..1000')
        raw = encoded(request.get('selection'))
        require(len(raw) <= MAX_SELECTION, 'selection exceeds 64 KiB')
        with database(self.data) as conn:
            tables = inventory(conn)
            if operation == 'rows':
                recipe, locator, kind = selection_recipe(raw, tables)
                rows, more = selected_rows(conn, recipe, locator, offset, limit)
            else:
                review = relation_rows if operation == 'related' else referencing_rows
                recipe, locator, kind, rows, more, metadata = review(conn, raw, tables, offset, limit, self.digest)
                context.update(metadata)
            return context | {'selection': recipe, 'locator': {'kind': kind, 'columns': locator}, 'rows': rows,
                              'offset': offset, 'limit': limit, 'has_more': more,
                              'next_offset': offset + len(rows) if more else None}


def server(workbench, port=0):
    class LoopbackServer(HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(5)
            return connection, address

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Do not log tokens, queries, or retained private values.

        def respond(self, status, data, kind='application/json; charset=utf-8'):
            self.send_response(status)
            for key, value in {'Content-Type': kind, 'Content-Length': str(len(data)), 'Cache-Control': 'no-store',
                'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
                'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"}.items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

        def host_ok(self):
            return self.headers.get('Host') == self.server.address

        def do_GET(self):
            if not self.host_ok():
                return self.respond(403, b'{"error":"invalid host"}')
            assets = {'/': ('index.html', 'text/html; charset=utf-8'),
                      '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
                      '/style.css': ('style.css', 'text/css; charset=utf-8')}
            if self.path not in assets:
                return self.respond(404, b'{"error":"not found"}')
            name, kind = assets[self.path]
            self.respond(200, (ASSETS / name).read_bytes(), kind)

        def do_POST(self):
            if not self.host_ok() or self.headers.get('Origin') != 'http://' + self.server.address or not secrets.compare_digest(self.headers.get('X-Review-Token', '').encode('utf-8'), workbench.token.encode('utf-8')):
                return self.respond(403, b'{"error":"local session authorization required"}')
            if self.path != '/api':
                return self.respond(404, b'{"error":"not found"}')
            try:
                require(self.headers.get('Content-Type') == 'application/json' and not self.headers.get('Transfer-Encoding'), 'JSON body required')
                length = int(self.headers.get('Content-Length', '-1'))
                require(0 < length <= 3 * MAX_SELECTION, 'request exceeds bound')
                self.connection.settimeout(5)
                raw = self.rfile.read(length)
                require(len(raw) == length, 'incomplete request')
                request = json.loads(raw)
                # Bootstrap needs a secret token too; it reveals only this pinned session.
                response = {'session': workbench.session, 'database_sha256': workbench.digest} if request == {'operation': 'bootstrap'} else workbench.dispatch(request)
                data = encoded(response)
                require(len(data) <= MAX_OUTPUT, 'response exceeds 16 MiB')
                self.respond(200, data)
            except (ValueError, TypeError, KeyError, RecursionError, UnicodeError, sqlite3.Error, OSError) as error:
                self.respond(400, encoded({'error': str(error)}))

    result = LoopbackServer(('127.0.0.1', port), Handler)
    result.address = '127.0.0.1:' + str(result.server_port)
    result.timeout = 5
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle')
    parser.add_argument('--database', required=True)
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    workbench = Workbench(args.bundle, args.database)
    with server(workbench, args.port) as http:
        print('Open http://' + http.address + '/#' + workbench.token, flush=True)
        print('Pinned database ' + workbench.digest + '; Ctrl-C closes the review session.', flush=True)
        try:
            http.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
