# Controlling Incus VMs via QMP

QEMU Machine Protocol (QMP) allows programmatic control of Incus VMs — sending keyboard/mouse input, taking screenshots, and querying VM state. This is useful for automating interaction with VMs that don't have an agent (e.g., Windows VMs).

## The Problem

Incus keeps a persistent, exclusive connection to the default QMP socket at `/run/incus/<vm>/qemu.monitor`. You cannot connect to it directly.

## Solution: Add a Second QMP Socket

Use Incus's `raw.qemu` config to add a second QMP monitor socket:

```bash
incus config set <vm> \
  raw.qemu='-chardev socket,id=mon2,path=/tmp/qmp-<vm>,server=on,wait=off -mon chardev=mon2,mode=control'
```

Then restart the VM. The socket will accept connections, and QEMU re-listens after each client disconnects.

**Important:** Use `-chardev` + `-mon` instead of the shorthand `-qmp unix:...,server,nowait`. The shorthand only accepts one connection ever; with `-chardev server=on,wait=off`, QEMU re-listens after disconnect so you can reconnect as many times as needed.

## Connecting

The socket requires root access (owned by the QEMU process). Use `sudo` or run scripts as root.

```bash
sudo nix-shell -p socat --run 'socat - unix-connect:/tmp/qmp-<vm>'
```

You'll see a JSON greeting. Send capabilities negotiation first:

```json
{"execute": "qmp_capabilities"}
```

## Sending Keyboard Input

Key names use QEMU "qcode" names: `a`-`z`, `0`-`9`, `ret` (Enter), `spc` (Space), `tab`, `esc`, `shift`, `ctrl`, `alt`, `backspace`, `up`, `down`, `left`, `right`, etc.

Press and release a key:

```json
{"execute": "input-send-event", "arguments": {"events": [
  {"type": "key", "data": {"down": true, "key": {"type": "qcode", "data": "ret"}}}
]}}
{"execute": "input-send-event", "arguments": {"events": [
  {"type": "key", "data": {"down": false, "key": {"type": "qcode", "data": "ret"}}}
]}}
```

## Sending Mouse Input

Absolute positioning (coordinates 0-32767, mapping to the VM's display resolution):

```json
{"execute": "input-send-event", "arguments": {"events": [
  {"type": "abs", "data": {"axis": "x", "value": 16000}},
  {"type": "abs", "data": {"axis": "y", "value": 16000}}
]}}
```

Mouse click (left button):

```json
{"execute": "input-send-event", "arguments": {"events": [
  {"type": "btn", "data": {"down": true, "button": "left"}}
]}}
{"execute": "input-send-event", "arguments": {"events": [
  {"type": "btn", "data": {"down": false, "button": "left"}}
]}}
```

Note: Incus VMs include a `virtio-tablet` device by default which supports absolute positioning. If mouse input doesn't register, check the QEMU config at `/run/incus/<vm>/qemu.conf`.

## Taking Screenshots

Two options:

### Via QMP (saves to host filesystem as PPM, owned by root)

```json
{"execute": "screendump", "arguments": {"filename": "/tmp/screenshot.ppm"}}
```

### Via Incus API (returns PNG, no root required — recommended)

```bash
incus query --raw /1.0/instances/<vm>/console?type=vga > screenshot.png
```

## Windows VMs: Virtio Driver Bootstrap

Incus presents disks via virtio-scsi, which Windows doesn't have drivers for out of the box. To boot a Windows disk image imported from another hypervisor:

1. Attach the `virtio-win.iso` via IDE (not virtio) so WinRE can see it:
   ```bash
   incus config set <vm> raw.qemu='... -drive file=/path/to/virtio-win.iso,media=cdrom,readonly=on,id=virtio-cd'
   ```
   (Append to existing `raw.qemu` value if you already have the QMP socket configured.)

2. Boot into Windows Recovery Environment (WinRE) and open Command Prompt.

3. Load the virtio-scsi driver so the Windows disk becomes visible:
   ```
   drvload D:\vioscsi\w10\amd64\vioscsi.inf
   ```

4. Install drivers permanently into the offline Windows image:
   ```
   dism /image:C:\ /add-driver /driver:D:\vioscsi\w10\amd64\vioscsi.inf
   dism /image:C:\ /add-driver /driver:D:\NetKVM\w10\amd64\netkvm.inf
   dism /image:C:\ /add-driver /driver:D:\Balloon\w10\amd64\balloon.inf
   ```

5. Rebuild boot configuration:
   ```
   bcdboot C:\windows /s C: /f UEFI
   ```

6. Reboot — Windows should now boot normally with virtio drivers.

## Python Example

```python
import socket, json, time

SOCKET_PATH = "/tmp/qmp-<vm>"

def qmp_connect():
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    sock.settimeout(2)
    sock.recv(4096)  # greeting
    sock.sendall(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
    time.sleep(0.2)
    sock.recv(4096)  # response
    return sock

def send(sock, cmd, **args):
    msg = {"execute": cmd}
    if args:
        msg["arguments"] = args
    sock.sendall(json.dumps(msg).encode() + b"\n")
    time.sleep(0.1)
    try:
        sock.recv(4096)
    except socket.timeout:
        pass

def send_key(sock, key):
    for down in [True, False]:
        send(sock, "input-send-event", events=[
            {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": key}}}
        ])

def click(sock, x_pct, y_pct):
    """Click at percentage coordinates (0-100)"""
    x = int(x_pct / 100.0 * 32767)
    y = int(y_pct / 100.0 * 32767)
    send(sock, "input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": x}},
        {"type": "abs", "data": {"axis": "y", "value": y}}
    ])
    time.sleep(0.1)
    send(sock, "input-send-event", events=[
        {"type": "btn", "data": {"down": True, "button": "left"}}
    ])
    send(sock, "input-send-event", events=[
        {"type": "btn", "data": {"down": False, "button": "left"}}
    ])

def type_text(sock, text):
    """Type a string character by character"""
    for ch in text:
        send_key(sock, ch)

sock = qmp_connect()
send_key(sock, "ret")       # Press Enter
type_text(sock, "hello")    # Type "hello"
click(sock, 50, 50)         # Click center of screen
sock.close()
```

## References

- [QEMU QMP Reference](https://qemu-project.gitlab.io/qemu/interop/qemu-qmp-ref.html)
- [QEMU input-send-event](https://qemu-project.gitlab.io/qemu/interop/qemu-qmp-ref.html#qapidoc-590)
- [Incus raw.qemu docs](https://linuxcontainers.org/incus/docs/main/reference/instance_options/)
