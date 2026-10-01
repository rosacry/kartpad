# DolphiniOS Xbox preset: source candidate

Status: portable C++ logic tested on Windows; Apple frontend changes and Apple framework tests have **not** been compiled or run. No modified IPA has been produced or installed. Exact in-game feel is still unverified.

Base: official KartPad v0.7.3, commit `9f973c4ecc46284edfba06eb7dede67f629eb4c5`.

## Behavior

The optional preset applies to Player 1 with an Extended Gamepad. It uses the supplied GCPad1 expressions and exposes their gameplay actions through KartPad's Classic Controller input path:

| Physical input | Preset action |
| --- | --- |
| Left stick | Signed per-axis `pow(abs(value), 1.3)`, then KartPad byte scaling |
| Right stick | Linear, matching the saved C-stick expressions |
| A / B / X / Menu | Accelerate / brake / rear view / pause |
| Left shoulder | Item (Classic L) and D-pad Down together |
| Right shoulder | D-pad Up; no added drift or trigger pressure |
| Right trigger | Drift at input >= 0.60; evaluate before byte quantization |
| Left trigger | Analog value retained; no extra digital button binding |
| D-pad Left / Right | Corresponding directions |
| Y | 50 ms drift pulse; `pulse(hold(Y, 0.016667), 0.05)` for Down |

Physical D-pad Up/Down and a plain game Y button are not bound in the supplied profile. A full trigger press makes the analog output full strength, as Dolphin's MixedTriggers does. KartPad's current Classic adapter consumes the digital drift action; analog trigger output alone is not an equivalent to all GameCube controller behavior.

The threshold's deadzone was checked in the **installed DolphiniOS v5.0.0b6 source**. `AddDeadzoneSetting(..., 25)` passes the allowed maximum, not the default. The default is **zero**. No deadzone override exists in the supplied GCPad1 config, so 60% remains 60% of the reported trigger value.

### Y timing

The timed expressions run on input polls, even without new controller callbacks. A press adds 50 ms to an existing pulse rather than restarting its expiry. An active pulse survives release; holding Y does not repeat it indefinitely. Down requires the hold expression to have activated at a poll.

Dolphin's hold clock starts at the last *released input poll*. Therefore `0.016667` is not a guaranteed exact physical-button-to-Down delay or exactly one rendered frame. This candidate retains that sampled behavior, using integer microsecond timestamps. The real controller and game polling cadence still needs iPad testing.

At connection, preset changes, background/resume, and return from the host main menu, the shortcut is reset and requires an observed Y release before firing. This deliberate lifecycle safeguard prevents an old held Y from starting a new pulse. A tap entirely between input polls can be missed, as in a sampled Dolphin expression; ordinary mapped buttons retain KartPad's existing press latches.

## Native integration

Controller Setup gains a Player 1 preset switch. The standard preset remains the default. Other players, touch input, and saved standard button assignments retain their existing path. All iOS Player 1 reads now go through `consumeMergedPlayerOne` so Y expiry does not depend on a controller event. The portable header is shared by production code and Windows tests.

No save, license, Mii, rating, network identity, or server-login code is changed. Rumble and other host options are outside this change. Test physical controls with motion steering and controller auto-accelerate disabled before assessing parity with the old setup.

## Validation

Executed with LLVM/Clang 21.1.8 on Windows, C++20, `-Wall -Wextra -Wpedantic -Werror`:

- 8 passing test groups; 20,001 curve samples check symmetry, monotonicity and range.
- Golden values distinguish the curved left stick from the linear right stick.
- Trigger tests cover below/at/above 0.60, including inputs that round to the same byte.
- Timing traces cover held Y, early release, pulse completion after release, repeated taps extending a pulse, no repeat while held, polling-dependent hold timing, reset/rearm and clock rollback.
- Shoulder mappings, invalid numeric inputs, and independent shortcut instances are checked.

The CMake target is `kartpad_dolphin_profile_tests`. A standalone run needs only a C++20 compiler:

```sh
clang++ -std=c++20 -Wall -Wextra -Wpedantic -Werror runtime/tests/dolphin_profile_tests.cpp -o dolphin-profile-tests
./dolphin-profile-tests
```

Added native coverage to `kartpad_mobile_physical_controller_tests` for the actual Player 1 mixer, Classic L item mapping, threshold, Y/reset, Player 2 isolation, and disconnect. **These Apple framework tests are pending**, as are the iOS compiler, UI, controller and race tests. Portable tests do not substitute for them.

## Completing the app

The existing personal IPA built on Windows contains the unchanged official shell and **does not contain this preset**. PadMint's Windows packaging step cannot apply Objective-C++ source changes to that shell.

The next build stage requires the project's Apple Silicon Mac/Xcode toolchain. Apply the patch to the exact base above, run the portable and Apple controller tests, and build a new empty shell with the official `scripts/build-ios-app.sh` workflow and its pinned DiscIO dependency. Audit that empty shell before combining it locally with the already prepared personal game pack. No game code, disc, save, pairing file, or signing material is needed in a remote empty-shell build. No remote build or upload has been started.

Before accepting the controller port, perform an offline A/B test on the same Xbox controller: steering at several magnitudes, threshold crossing, Y short/held/repeated presses, disconnect/reconnect, and suspend/resume. Compare actual gameplay actions because Dolphin supplies GameCube input while KartPad supplies Classic input. Do not claim exact overall feel from the curve tests alone.

Online identity migration remains a separate unresolved item. This controller patch does not resolve it, and no login using the migrated identity has been attempted.

## Primary sources checked

- [KartPad v0.7.3 Apple build requirements](https://github.com/chrissotraidis/kartpad/blob/v0.7.3/docs/BUILDING.md)
- [KartPad v0.7.3 physical-controller path](https://github.com/chrissotraidis/kartpad/blob/v0.7.3/apple/mobile/KartPadPhysicalControllers.mm)
- [DolphiniOS v5.0.0b6 pulse and hold](https://github.com/OatmealDome/dolphin-ios/blob/v5.0.0b6/Source/Core/InputCommon/ControlReference/FunctionExpression.cpp)
- [DolphiniOS trigger comparison](https://github.com/OatmealDome/dolphin-ios/blob/v5.0.0b6/Source/Core/InputCommon/ControllerEmu/ControlGroup/MixedTriggers.cpp)
- [DolphiniOS zero default deadzone](https://github.com/OatmealDome/dolphin-ios/blob/v5.0.0b6/Source/Core/InputCommon/ControllerEmu/ControlGroup/ControlGroup.cpp)

The preset implementation and its modifications use KartPad's GPL-3.0-only license. The timing behavior was checked against Dolphin's GPL-2.0-or-later source; the code here is a small purpose-specific implementation with the documented lifecycle change.
