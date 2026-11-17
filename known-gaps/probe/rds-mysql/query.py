"""Run SQL against the emulator's RDS for MySQL, with no MySQL client installed.

    python3 query.py HOST PORT USER PASSWORD DATABASE "SQL; SQL; ..."

Speaks just enough of the MySQL protocol for a check: the handshake,
mysql_native_password, and text queries. Prints each result as rows, or
"ok" for statements that return none. Standard library only.
"""
import hashlib
import socket
import struct
import sys


def read_packet(sock):
    head = b""
    while len(head) < 4:
        chunk = sock.recv(4 - len(head))
        if not chunk:
            raise ConnectionError("server closed the connection")
        head += chunk
    length = head[0] | head[1] << 8 | head[2] << 16
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            raise ConnectionError("server closed the connection")
        body += chunk
    return head[3], body


def send_packet(sock, seq, body):
    sock.sendall(struct.pack("<I", len(body))[:3] + bytes([seq]) + body)


def lenenc_int(data, i):
    first = data[i]
    if first < 0xFB:
        return first, i + 1
    if first == 0xFC:
        return struct.unpack_from("<H", data, i + 1)[0], i + 3
    if first == 0xFD:
        return int.from_bytes(data[i + 1:i + 4], "little"), i + 4
    return struct.unpack_from("<Q", data, i + 1)[0], i + 9


def lenenc_str(data, i):
    if data[i] == 0xFB:  # NULL
        return None, i + 1
    n, i = lenenc_int(data, i)
    return data[i:i + n].decode(), i + n


def scramble(password, salt):
    if not password:
        return b""
    one = hashlib.sha1(password.encode()).digest()
    two = hashlib.sha1(one).digest()
    three = hashlib.sha1(salt + two).digest()
    return bytes(a ^ b for a, b in zip(one, three))


def error(body):
    code = struct.unpack_from("<H", body, 1)[0]
    return f"ERROR {code}: {body[9:].decode(errors='replace')}"


def connect(host, port, user, password, database):
    sock = socket.create_connection((host, port), timeout=10)
    _, hello = read_packet(sock)
    version_end = hello.index(b"\0", 1)
    version = hello[1:version_end].decode()
    i = version_end + 1 + 4
    salt = hello[i:i + 8]
    i += 8 + 1 + 2 + 1 + 2 + 2
    salt_len = hello[i]
    i += 1 + 10
    salt += hello[i:i + max(13, salt_len - 8) - 1]
    flags = 0x0200 | 0x8000 | 0x0008 | 0x80000  # protocol 41, secure conn, db, plugin auth
    auth = scramble(password, salt)
    body = (struct.pack("<IIB", flags, 1 << 24, 33) + b"\0" * 23
            + user.encode() + b"\0" + bytes([len(auth)]) + auth
            + database.encode() + b"\0" + b"mysql_native_password\0")
    send_packet(sock, 1, body)
    _, reply = read_packet(sock)
    if reply[0] == 0xFF:
        raise SystemExit(error(reply))
    return sock, version


def query(sock, sql):
    send_packet(sock, 0, b"\x03" + sql.encode())
    _, first = read_packet(sock)
    if first[0] == 0xFF:
        return error(first)
    if first[0] == 0x00:
        return "ok"
    columns, _ = lenenc_int(first, 0)
    names = []
    for _ in range(columns):
        _, col = read_packet(sock)
        i = 0
        for _ in range(4):  # catalog, schema, table, org_table
            _, i = lenenc_str(col, i)
        name, _ = lenenc_str(col, i)
        names.append(name)
    _, eof = read_packet(sock)
    rows = []
    while True:
        _, row = read_packet(sock)
        if row[0] in (0xFE, 0xFF) and len(row) < 9:
            break
        i, values = 0, []
        for _ in range(columns):
            value, i = lenenc_str(row, i)
            values.append(value)
        rows.append(values)
    return "\n".join([" | ".join(names)] + [" | ".join(str(v) for v in r) for r in rows])


def main():
    host, port, user, password, database, sql = sys.argv[1:7]
    sock, version = connect(host, int(port), user, password, database)
    print(f"connected: server {version}")
    for statement in [s.strip() for s in sql.split(";") if s.strip()]:
        print(f"> {statement}")
        print(query(sock, statement))


if __name__ == "__main__":
    main()
