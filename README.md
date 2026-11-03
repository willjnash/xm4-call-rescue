# xm4-call-rescue

Fixes the Sony WH-1000XM4 + macOS bug where taking the headphones off during a call
(Zoom, Teams, Meet…) silences the call, and putting them back on doesn't bring the audio back.

**Cause (from bluetoothd/coreaudiod logs):** when you take them off, the headset closes the HFP voice
link (`Received voice disconnection event … Disconnecting SCO`). CoreAudio still reports the
device as running, so macOS never re-creates the link and the call keeps sending audio to a dead channel.

**Fix:** a small background agent watches the log for that event. If a headset mic is still in use about 0.3s after the drop, it briefly moves the system default output and input off the headset and back (or onto it and back, if the headset is not the default). That makes coreaudiod re-create the voice link, typically within half a second, even when the app picked the headset explicitly. It retries every 1.5s while the headphones are still off.

## Install / uninstall

    ./install.sh --address 88:C9:E8:7A:F7:00   # address optional; omit to cover any headset
    ./install.sh --uninstall

Logs: `~/Library/Logs/xm4-call-rescue.log`

## Caveats

- Each fix attempt makes the built-in speakers and mic the defaults for ~0.1s each. If your call app follows the system default, a fraction of a second of call audio may come from the Mac speakers.
