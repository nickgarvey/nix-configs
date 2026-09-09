import asyncio
import json
import subprocess
import urllib.request

import websockets

CDP = "http://127.0.0.1:8080"
TARGET = "Steam Big Picture Mode"
BINDING = "__tvStandby"
ACTION = ["tv", "standby"]

# The Power submenu is rebuilt every time it opens, so the row cannot simply be
# inserted once -- a MutationObserver re-adds it on each open. Anchoring on the
# semantic contextMenuItem class plus the row text avoids depending on Steam's
# hashed class names, which churn between releases.
INJECT = """
(function () {
  // Re-installable: a previous injection keeps running with its own copy of
  // this code, so tear it down and undo its edits first.
  if (window.__tvMenuObserver) window.__tvMenuObserver.disconnect();
  Array.prototype.slice.call(document.querySelectorAll("[data-tv-off]"))
    .forEach(function (n) {
      if (n.dataset.tvOrig) {
        n.textContent = n.dataset.tvOrig;   // hijacked row: put the label back
        delete n.dataset.tvOrig;
      } else {
        n.remove();                         // older versions injected a row
      }
      delete n.dataset.tvOff;
    });

  // Steam drives menu navigation from its own React registry, so a row we
  // append is rendered but never focusable -- the controller walks straight
  // past it. Repurposing a row Steam already registered is the only way to
  // get something the controller can actually select. "Switch to Desktop" is
  // the one to take: greetd offers no desktop session on this host, so
  // choosing it today just strands you.
  window.__tvHandler = window.__tvHandler || function (e) {
    e.stopPropagation();   // suppress Steam's own action for this row
    e.preventDefault();
    window.__tvStandby("");
  };

  function hijack() {
    Array.prototype.slice.call(document.querySelectorAll("div.contextMenuItem"))
      .forEach(function (r) {
        if (r.dataset.tvOff) return;
        if ((r.textContent || "").trim() !== "Switch to Desktop") return;
        r.dataset.tvOrig = "Switch to Desktop";
        r.dataset.tvOff = "1";
        r.textContent = "Turn Off TV";
        // Same function reference each time, so re-running is idempotent.
        r.addEventListener("click", window.__tvHandler, true);
      });
  }

  // The Power submenu is rebuilt every time it opens, so re-apply on mutation.
  window.__tvMenuObserver = new MutationObserver(hijack);
  window.__tvMenuObserver.observe(
    document.body, { childList: true, subtree: true });
  hijack();
  return "installed";
})()
"""


# Dismiss the Power menu once the TV is actually off, so the menu closing is
# confirmation the command landed rather than just that the row was pressed.
# Cancel is Steam's own close action and is not hijacked, so clicking it is
# the least surprising way to do this.
CLOSE = """
(function () {
  var c = Array.prototype.slice.call(
    document.querySelectorAll("div.contextMenuItem")).filter(function (r) {
      return (r.textContent || "").trim() === "Cancel";
    })[0];
  if (!c) return "menu already closed";
  ["pointerdown", "mousedown", "pointerup", "mouseup", "click"].forEach(
    function (t) {
      c.dispatchEvent(new MouseEvent(t,
        { bubbles: true, cancelable: true, view: window }));
    });
  return "closed";
})()
"""


def target_ws():
    with urllib.request.urlopen(CDP + "/json/list", timeout=5) as r:
        for t in json.load(r):
            if TARGET in t.get("title", ""):
                return t["webSocketDebuggerUrl"]
    return None


async def send(ws, mid, method, params):
    await ws.send(json.dumps({"id": mid, "method": method, "params": params}))


async def session(url):
    async with websockets.connect(url, max_size=None) as ws:
        await send(ws, 1, "Runtime.enable", {})
        await send(ws, 2, "Runtime.addBinding", {"name": BINDING})
        await send(ws, 3, "Runtime.evaluate",
                   {"expression": INJECT, "returnByValue": True})
        print("connected, injector installed", flush=True)
        while True:
            try:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
            except asyncio.TimeoutError:
                # Steam rebuilds the UI on navigation; re-assert cheaply. The
                # page-side guard makes this a no-op when already present.
                await send(ws, 2, "Runtime.addBinding", {"name": BINDING})
                await send(ws, 3, "Runtime.evaluate",
                           {"expression": INJECT, "returnByValue": True})
                continue
            if msg.get("method") == "Runtime.bindingCalled" and \
                    msg.get("params", {}).get("name") == BINDING:
                print("menu entry activated -> %s" % " ".join(ACTION), flush=True)
                try:
                    out = subprocess.run(ACTION, capture_output=True, text=True,
                                         timeout=15)
                    result = (out.stdout.strip() + out.stderr.strip())
                    print("action: %s" % result, flush=True)
                    if out.returncode == 0 and "OK" in out.stdout:
                        await send(ws, 4, "Runtime.evaluate",
                                   {"expression": CLOSE, "returnByValue": True})
                        print("closing power menu", flush=True)
                except Exception as exc:
                    print("action failed: %s" % exc, flush=True)


async def main():
    while True:
        try:
            url = target_ws()
            if url:
                await session(url)
            else:
                print("no %s target yet" % TARGET, flush=True)
        except Exception as exc:
            print("disconnected: %s" % exc, flush=True)
        await asyncio.sleep(5)


asyncio.run(main())
