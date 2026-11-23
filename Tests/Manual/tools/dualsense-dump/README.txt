dualsense-dump: records a DualSense (PS5) controller for MacPopup
==================================================================

Thank you for helping! This little tool records what your DualSense sends to the Mac (its raw input data) and what
macOS's game controller support says is pressed, while you press each control. It doesn't change any settings,
doesn't send anything to the controller, and doesn't press keys or move the mouse. When you stop it, it saves one
file: please send us that file.

What you need
-------------
- A Mac with the Xcode Command Line Tools. If you don't have them, the first command below will offer to install
  them (or run: xcode-select --install).
- The DualSense connected by USB cable or paired over Bluetooth (System Settings > Bluetooth). Only one DualSense
  connected, please. Other controllers can stay connected.
- About 5 minutes.

Build and run
-------------
1. Put dualsense-dump.swift and build.sh in a folder, e.g. Downloads/dualsense-dump.
2. Open Terminal (Applications > Utilities > Terminal) and type:

       cd ~/Downloads/dualsense-dump
       sh build.sh
       ./dualsense-dump

   (Instead of building, "swift dualsense-dump.swift" also runs it, just slower to start.)

3. It shows the controller it found, then guides you step by step: each step starts after a short pause with a
   sound. During the pauses, let go of everything; during a step, press only what it says, cleanly, and nothing
   else. The bottom line shows what's being recorded and what's held, so you can see it working.
4. When it says "All steps done", press Ctrl-C (Control and C). It saves a file named like
   dualsense-1794562177.json in the same folder and prints where it is.

You can press Ctrl-C at any time: what was recorded so far is saved. If you'd rather not follow the steps, run
"./dualsense-dump --free" and press every button, the D-pad, both sticks (each direction, and a slow circle) and
both triggers (slowly) a few times, one at a time, then press Ctrl-C.

If you can, please do it twice: once with the USB cable, and once over Bluetooth (unplug the cable; the controller
stays paired). Each run makes its own file.

Notes
-----
- Pressing the PS button may make macOS open something (e.g. Launchpad or Game Center). Just ignore it; the
  recording carries on. You can come back to Terminal afterwards.
- Keep the controller still on a table or loosely in your hands, so the sticks and triggers rest untouched while
  you press other buttons.

If macOS asks for permission (Input Monitoring)
-----------------------------------------------
macOS may say Terminal wants to "receive keystrokes from any application", or the tool may say it couldn't open the
controller. Reading a controller directly can need the Input Monitoring permission:

1. Open System Settings > Privacy & Security > Input Monitoring.
2. Turn on Terminal (if it isn't listed, click + and add Applications > Utilities > Terminal).
3. Quit Terminal completely (Terminal menu > Quit Terminal, or Cmd-Q), open it again and run the tool again.
   The permission only takes effect after Terminal restarts.

You can turn it off again afterwards in the same place.

If it says no DualSense was found
---------------------------------
Check the controller is on (light bar lit) and connected: plug the cable in, or for Bluetooth hold the PS button
until it connects. If it says several are connected, leave only one connected.

Sending us the file
-------------------
Please send the dualsense-<number>.json file(s) back to us the same way you got this tool (e.g. attach them to an
email or the message thread). It may help to zip them first (right-click > Compress), which makes them much smaller.
The file only contains the controller's data, its button names and your macOS version; nothing else from
your Mac.
