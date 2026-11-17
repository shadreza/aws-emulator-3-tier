"""Opens a MySQL connection from inside Lambda and runs one query.

Uses query.py from ../rds-mysql (standard library only), copied into the zip
by run.sh.
"""
import query


def handler(event, context):
    try:
        sock, version = query.connect(event["host"], int(event["port"]),
                                      "app", "probe-only-local-1", "probe")
        result = query.query(sock, "SELECT 6*7").splitlines()[-1]
        sock.close()
        return {"ok": True, "server": version, "result": result}
    except BaseException as e:  # query.connect raises SystemExit on a refused login
        return {"ok": False, "error": f"{type(e).__name__}: {e}"[:200]}
