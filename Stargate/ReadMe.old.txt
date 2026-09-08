===============================================
  STARGATE DIALING COMPUTER v5.0
  For CC:Tweaked + Stargate Journey
  Created by: Jacob + Claude
===============================================

ABOUT
-----
This program provides a touch-screen interface
for controlling Stargates via ComputerCraft.
It automatically detects your gate type and
provides appropriate dialing controls.

FEATURES
--------
- Auto-detects gate type and interface
- Touch screen GUI with buttons
- Destination address book
- Real-time status monitoring
- Energy display
- Chevron lock indicators
- Iris control (if installed)
- Event log with timestamps
- Remote API control support
- Works with ALL Stargate types

SUPPORTED GATES
---------------
Gate Type     Interface       Iris
---------     ---------       ----
Classic       Basic           Yes
Milky Way     Basic           Yes
Universe      Crystal/Adv     Yes
Pegasus       Crystal/Adv     Yes
Tollan        Crystal/Adv     No

REQUIREMENTS
------------
Hardware:
- Computer (normal or advanced)
- ADVANCED MONITOR (required for touch)
  * Normal monitors will NOT work
  * Touch events require advanced monitor
- Stargate Interface (any type)
- Wired Modems + Network Cables
- Stargate (any type)

IMPORTANT: The monitor MUST be an advanced
monitor (gold border). Normal monitors do not
support touch events and the buttons will not
work!

INSTALLATION
------------
1. Place computer next to ADVANCED monitor
   OR connect via wired modem network

2. Connect Stargate interface to computer
   via wired modems and network cables

3. Turn on both modems (right-click)

4. Copy this program to the computer

5. Run the program

FIRST-TIME SETUP
----------------
After swapping gates, you MUST:
1. Shut down the computer
2. Break and replace the interface
3. Reconnect network cables
4. Toggle modems on
5. Restart the computer

This is a CC:Tweaked limitation - the
interface needs to refresh its connection.

CONFIGURATION
-------------
Edit these values at the top of the script:

CONFIG = {
    STARGATE_NAME = "Earth"
    Change this to your gate's name

    API_URL = "http://..."
    Your API endpoint (if using remote control)

    API_ENABLED = true
    Set to false to disable API

    DEBUG_MODE = true
    Shows detailed logs in terminal
}

DESTINATIONS = {
    ["Name"] = {symbol, list, here, 0}
}
Add your gate addresses here

USAGE - MAIN SCREEN
-------------------
The main screen shows:
- Gate type and interface type
- Current status (Idle/Dialing/Connected)
- Energy level with progress bar
- Chevron lock indicators
- Iris status (if installed)
- Event log

BUTTONS:
[DIAL] - Opens destination selector
[DISCONNECT] - Closes active wormhole
[IRIS OPEN] - Opens iris
[IRIS CLOSE] - Closes iris
[REFRESH HARDWARE] - Re-scans peripherals

USAGE - DIALING
---------------
1. Click [DIAL] button
2. Select destination from list
3. Wait for dial sequence to complete
4. Step through the wormhole!

To add destinations:
Edit the DESTINATIONS table in the code

Format: 7 or 9 symbols, ending with 0
Example: {26, 6, 14, 31, 11, 29, 0}

IRIS CONTROL
------------
Iris Progress Values:
  0 = Fully open
  1-57 = Moving
  58 = Fully closed

The display shows:
- "OPEN" when progress = 0
- "CLOSED" when progress = 58
- "MOVING (X/58)" when in motion

Smart logging prevents trying to open an
already-open iris or close an already-closed
iris.

ENERGY DISPLAY
--------------
Shows current gate energy as a percentage.
The progress bar is capped at 100% even if
the gate reports higher values.

CHEVRON INDICATORS
------------------
Shows 7 chevrons:
< > = Unlocked
<#> = Locked

During dialing, chevrons lock one by one
as symbols are encoded.

EVENT LOG
---------
Bottom of screen 