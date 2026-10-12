# BlueClues

## Why I built this

While I was in Ukraine, I noticed the same person several times in one day. Each time they were wearing different clothes, so I could never be sure I was actually being followed. Clothes change. The phone, earbuds and watch in someone's pocket usually don't.

BlueClues is a personal awareness and safety tool built on that idea. It listens to the Bluetooth devices around you and tells you when the same ones keep turning up.

## What it does

BlueClues runs on iPhone and scans for nearby Bluetooth Low Energy devices, logging each sighting with the time and where you were.

**Two modes**

- **In Motion**: for walking or travelling. A device that shows up at two places at least 250 m apart, over at least 5 minutes, triggers an alert. Passing the same device twice on an out-and-back walk counts as one place and doesn't alert.
- **Stationary**: for home, a hotel or an office. A device that stays near you for 20 minutes straight, or comes and goes three separate times in 24 hours, triggers an alert.

**Trackers**: recognises AirTag-style Find My accessories, Tile, Samsung SmartTag, Google Find My Device tags and Chipolo, including whether a tag is separated from its owner. iOS limits what third-party apps can see of AirTags, so keep iPhone's built-in tracker alerts on too.

**Possible followers**: phones, watches and earbuds change their Bluetooth address every few minutes. BlueClues groups them by how they broadcast instead, and raises a weaker "Possible follower nearby" alert when the same kind of device shows up at three of your locations. Treat it as worth a look, not proof.

**Labels**: mark any device as Mine, Friendly or Questionable. Mine and Friendly never alert. Questionable alerts every time it comes back.

**Who made this?**: guesses each device's maker and type (phone, earbuds, watch, TV, car, tracker and so on) from what it broadcasts, with a confidence level and the evidence. Tap a device for ranked suggestions, confirm one or type your own.

**Where it was seen**: every log entry and sighting stores your location. Each device shows a map of the places it was spotted.

**Optional AI second opinion** (off by default): ask about a single device using Apple's on-device model, Apple's Private Cloud model, or your own OpenAI-compatible or Anthropic API key. You see exactly what will be sent first: only the device's broadcast data, never locations or times. API keys stay in the iPhone's Keychain.

**iCloud sync**: devices, labels and logs sync to your own private iCloud database. This needs the app to be signed with a paid Apple Developer account.

**Export**: everything can be exported as CSV, including raw broadcast data.

## Privacy

There is no BlueClues server. Your data stays on your phone and, if you turn on sync, in your own iCloud. The developer never receives any of it.

## Building

Open `BluesClues.xcodeproj` in Xcode, choose your team under Signing & Capabilities, and run it on an iPhone. Bluetooth scanning doesn't work in the Simulator. Grant Bluetooth, Location ("Always" for background use) and Notifications when asked.

## License

MIT. See [MIT License](MIT%20License).
