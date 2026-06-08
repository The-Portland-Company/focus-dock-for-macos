#!/usr/bin/env python3
"""Finalize the Mac App Store submission for Focus: Dock once the App Privacy
data-usage answers have been published in App Store Connect (web UI only).

Prereqs: pip3 install pyjwt cryptography
Key: ~/.appstoreconnect/private_keys/AuthKey_XG3FW9LT9Q.p8
Run:  python3 scripts/asc_submit.py
"""
import jwt, time, json, urllib.request

KEY_ID = "XG3FW9LT9Q"
ISSUER = "178bab61-1c45-4f62-9525-55f8ed15a98d"
P8 = "/Users/spencerhill/.appstoreconnect/private_keys/AuthKey_XG3FW9LT9Q.p8"
APP = "6769601167"                                   # Focus: Dock
VER = "15d323d2-9a0d-4244-8925-bdf5cc9c5852"         # macOS 1.0 version


def token():
    now = int(time.time())
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                      open(P8).read(), algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def call(path, method="GET", body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 data=json.dumps(body).encode() if body else None, method=method)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")


def main():
    st, d = call("/v1/reviewSubmissions", "POST", {"data": {"type": "reviewSubmissions",
        "attributes": {"platform": "MAC_OS"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    if st >= 300:
        print("create submission failed", st, json.dumps(d)); return
    sub = d["data"]["id"]
    st, d = call("/v1/reviewSubmissionItems", "POST", {"data": {"type": "reviewSubmissionItems",
        "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub}},
                          "appStoreVersion": {"data": {"type": "appStoreVersions", "id": VER}}}}})
    if st >= 300:
        print("add item failed", st)
        for k, errs in d["errors"][0].get("meta", {}).get("associatedErrors", {}).items():
            for e in errs:
                print("  -", e["detail"])
        return
    st, d = call("/v1/reviewSubmissions/" + sub, "PATCH",
                 {"data": {"type": "reviewSubmissions", "id": sub, "attributes": {"submitted": True}}})
    print("submit", st, d.get("data", {}).get("attributes", {}).get("state") if st < 300 else json.dumps(d))


if __name__ == "__main__":
    main()
