#!/usr/bin/env python3
"""A stub AMap, for verifying the routing relay without a vendor key.

Returns one canned `/v5/direction/bicycling` body and appends every request
line it receives to the file given as argv[2], so the caller can assert that
the relay added the key and the fields the app's parser needs.
"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2] if len(sys.argv) > 2 else "/dev/null"

BODY = """{
  "status": "1",
  "info": "OK",
  "infocode": "10000",
  "route": {
    "origin": "116.407400,39.904200",
    "destination": "116.417400,39.914200",
    "paths": [
      {
        "distance": "1234",
        "duration": "300",
        "steps": [
          {"instruction": "向东骑行", "road_name": "人民大道",
           "step_distance": "600", "action": "straight",
           "polyline": "116.407400,39.904200;116.417400,39.904200",
           "cost": {"duration": "150"}},
          {"instruction": "左转进入北向路", "road_name": "北向路",
           "step_distance": "634", "action": "left",
           "polyline": "116.417400,39.904200;116.417400,39.914200",
           "cost": {"duration": "150"}}
        ]
      }
    ]
  }
}"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - stdlib naming
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(self.path + "\n")
        payload = BODY.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):  # keep the test output clean
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()
