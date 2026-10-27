#!/usr/bin/env python3
"""Tiny HTTP helper the UI test calls for steps it can't do itself.

POST /agent-reply  inserts a teammate reply into the setup-check conversation
                   and marks it unread for the visitor.
POST /push         delivers a simulated Wonderchat APNs push with `simctl push`.

Usage: harness_server.py <port> <sql.sh> <wonderchat repo> <chatbot id> <sim udid> <bundle id>
"""

import json
import subprocess
import sys
import tempfile
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, SQL, REPO, CHATBOT_ID, UDID, BUNDLE_ID = sys.argv[1:7]
PORT = int(PORT)


def sql(statement):
    out = subprocess.run(
        [SQL], input=statement, cwd=REPO, capture_output=True, text=True, timeout=60, check=True
    )
    return json.loads(out.stdout or "[]")


def quote(value):
    return "'" + value.replace("'", "''") + "'"


def setup_chatlog_id():
    rows = sql(
        'select c.id from "Chatlog" c join "ChatMessage" m on m."chatlogId" = c.id '
        f'where c."chatbotId" = {quote(CHATBOT_ID)} and m."userMessage" = \'Hello from setup\' '
        'order by m."createdAt" desc limit 1;'
    )
    if not rows:
        raise RuntimeError("no setup-check conversation found")
    return rows[0]["id"]


def agent_reply():
    chatlog_id = setup_chatlog_id()
    message_id = "e2e-" + uuid.uuid4().hex
    sql(
        'insert into "ChatMessage" (id, "chatlogId", type, "userMessage", "createdAt") '
        f"values ({quote(message_id)}, {quote(chatlog_id)}, 'AGENT', 'Reply from the team', now());"
    )
    # A real teammate reply only happens in a handed-over live chat, which
    # chat.sendAgentMessage leaves PENDING; the page marks it read only then.
    sql(
        'update "Chatlog" set "isReadByUser" = false, "isEscalatedToLiveSupport" = true, '
        f"status = 'PENDING' where id = {quote(chatlog_id)};"
    )
    return {"chatlogId": chatlog_id, "messageId": message_id}


def push():
    chatlog_id = setup_chatlog_id()
    payload = {
        "Simulator Target Bundle": BUNDLE_ID,
        "aps": {"alert": {"title": "Support", "body": "Reply from the team"}, "sound": "default"},
        "wonderchat": {"chatlogId": chatlog_id},
    }
    with tempfile.NamedTemporaryFile("w", suffix=".apns", delete=False) as f:
        json.dump(payload, f)
        path = f.name
    subprocess.run(["xcrun", "simctl", "push", UDID, BUNDLE_ID, path], check=True, capture_output=True, timeout=30)
    return {"chatlogId": chatlog_id}


ACTIONS = {"/agent-reply": agent_reply, "/push": push}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        action = ACTIONS.get(self.path)
        if not action:
            self.send_response(404)
            self.end_headers()
            return
        try:
            body, status = action(), 200
        except Exception as error:  # reported back to the test
            body, status = {"error": str(error)}, 500
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        print(f"[harness] {time.strftime('%H:%M:%S')} {self.path} -> {status} {body}", flush=True)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
