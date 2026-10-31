import assert from "node:assert/strict";
import type http from "node:http";
import test from "node:test";
import { allowedHost, allowedOrigin, DESKTOP_ORIGIN, passesOriginGuard } from "./originGuard.js";

const req = (headers: Record<string, string>) => ({ headers }) as unknown as http.IncomingMessage;

test("Origin: 無いか、デスクトップアプリの画面のものだけ通す", () => {
  assert.equal(allowedOrigin(req({})), true);
  assert.equal(allowedOrigin(req({ origin: DESKTOP_ORIGIN })), true);
  for (const origin of ["null", "http://127.0.0.1:8765", "http://localhost:8765", "http://localhost:3000", "file://", "https://example.com", "buddyos-desktop://app/", "BUDDYOS-DESKTOP://APP", ""]) {
    assert.equal(allowedOrigin(req({ origin })), false, origin);
  }
});

test("Host: 127.0.0.1 / localhost / [::1] だけ（番号は任意）", () => {
  for (const host of ["127.0.0.1:8765", "localhost:8765", "[::1]:8765", "127.0.0.1", "LOCALHOST:51234", "127.0.0.1:61000"]) {
    assert.equal(allowedHost(req({ host })), true, host);
  }
  for (const host of ["attacker.example:8765", "127.0.0.1.nip.io:8765", "evil.localhost:8765", "127.0.0.2:8765", "[::2]:8765", "127.0.0.1:99999", "127.0.0.1:abc", ""]) {
    assert.equal(allowedHost(req({ host })), false, host);
  }
  assert.equal(allowedHost(req({})), false);
});

test("両方を満たすときだけ通す", () => {
  assert.equal(passesOriginGuard(req({ host: "127.0.0.1:8765" })), true);
  assert.equal(passesOriginGuard(req({ host: "127.0.0.1:8765", origin: DESKTOP_ORIGIN })), true);
  assert.equal(passesOriginGuard(req({ host: "127.0.0.1:8765", origin: "null" })), false);
  assert.equal(passesOriginGuard(req({ host: "rebind.example:8765" })), false);
});
