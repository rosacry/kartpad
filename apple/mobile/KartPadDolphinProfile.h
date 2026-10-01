// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

// Private preset for the supplied GCPad1 profile. This is a mapping of gameplay
// actions to KartPad's Classic input path, not an arbitrary Dolphin INI parser.
namespace kartpad::mobile::dolphin_profile {

struct Sample {
  bool a = false, b = false, x = false, y = false, menu = false;
  bool leftShoulder = false, rightShoulder = false;
  bool left = false, right = false;
  double leftX = 0, leftY = 0, rightX = 0, rightY = 0;
  double leftTrigger = 0, rightTrigger = 0;
};

struct Shortcut {
  bool drift = false, down = false;
};

struct State {
  bool accelerate = false, brake = false, rearView = false, pause = false;
  bool item = false, drift = false, up = false, down = false;
  bool left = false, right = false;
  std::int8_t leftX = 0, leftY = 0, rightX = 0, rightY = 0;
  std::uint8_t leftTrigger = 0, rightTrigger = 0;
};

inline double Bounded(double value, double low, double high) noexcept {
  return std::isfinite(value) ? std::clamp(value, low, high) : 0.0;
}

inline double Curve(double value) noexcept {
  value = Bounded(value, -1, 1);
  return std::copysign(std::pow(std::abs(value), 1.3), value);
}

inline std::int8_t Axis(double value) noexcept {
  return static_cast<std::int8_t>(std::lround(Bounded(value, -1, 1) * 127));
}

inline std::uint8_t Pressure(double value) noexcept {
  return static_cast<std::uint8_t>(std::lround(Bounded(value, 0, 1) * 255));
}

inline State Transform(const Sample& sample, Shortcut shortcut = {}) noexcept {
  State state;
  state.accelerate = sample.a;
  state.brake = sample.b;
  state.rearView = sample.x;
  state.pause = sample.menu;
  // Item is the left trigger, matching the player's DolphiniOS habit, at the
  // same 60% threshold as drift. LB keeps only its D-pad Down role.
  state.item = Bounded(sample.leftTrigger, 0, 1) >= 0.6;
  state.up = sample.rightShoulder;
  state.down = sample.leftShoulder || shortcut.down;
  state.left = sample.left;
  state.right = sample.right;
  // DolphiniOS 5.0.0b6 MixedTriggers compares >= before byte quantization.
  // The supplied profile has no deadzone override; its default is ZERO.
  state.drift = Bounded(sample.rightTrigger, 0, 1) >= 0.6 || shortcut.drift;
  state.leftX = Axis(Curve(sample.leftX));
  state.leftY = Axis(Curve(sample.leftY));
  state.rightX = Axis(sample.rightX);
  state.rightY = Axis(sample.rightY);
  state.leftTrigger = state.item ? 255 : Pressure(sample.leftTrigger);
  state.rightTrigger = state.drift ? 255 : Pressure(sample.rightTrigger);
  return state;
}

// Matches the sampled pulse/hold behavior in DolphiniOS v5.0.0b6
// Source/Core/InputCommon/ControlReference/FunctionExpression.cpp.
// A repeated press adds 50 ms to an active pulse. Releasing Y does not cancel
// an already started pulse. Hold measures time from the last released sample,
// so its observed delay depends on the game's input polling cadence.
class TimedShortcut {
 public:
  void Reset() noexcept { *this = {}; }

  Shortcut Poll(bool y, std::int64_t nowUs) noexcept {
    if (!initialized_ || nowUs < previousPoll_) {
      Reset();
      initialized_ = true;
      lastReleased_ = nowUs;
    }
    previousPoll_ = nowUs;
    // On connection, preset changes and resume, require a released Y sample.
    // This avoids generating a delayed action from a button held in the UI.
    if (!y) {
      armed_ = true;
      lastReleased_ = nowUs;
      held_ = false;
    }
    if (!armed_) return {};
    if (y && nowUs - lastReleased_ >= 16667) held_ = true;
    return {drift_.Poll(y, nowUs), down_.Poll(held_, nowUs)};
  }

 private:
  struct Pulse {
    bool released = false, active = false;
    std::int64_t end = 0;
    bool Poll(bool input, std::int64_t nowUs) noexcept {
      if (!input) {
        released = true;
      } else if (released) {
        released = false;
        end = active ? end + 50000 : nowUs + 50000;
        active = true;
      }
      if (active && nowUs >= end) active = false;
      return active;
    }
  };
  Pulse drift_, down_;
  bool initialized_ = false, armed_ = false, held_ = false;
  std::int64_t previousPoll_ = 0, lastReleased_ = 0;
};

}  // namespace kartpad::mobile::dolphin_profile
