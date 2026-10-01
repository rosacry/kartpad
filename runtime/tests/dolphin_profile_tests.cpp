// SPDX-License-Identifier: GPL-3.0-only
#include "../../apple/mobile/KartPadDolphinProfile.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace P = kartpad::mobile::dolphin_profile;

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void Expect(P::TimedShortcut& shortcut, bool y, std::int64_t time,
            bool drift, bool down) {
  const auto value = shortcut.Poll(y, time);
  if (value.drift != drift || value.down != down) {
    std::cerr << "At " << time << " us, Y=" << y << ": got "
              << value.drift << ',' << value.down << "; expected "
              << drift << ',' << down << '\n';
    throw std::runtime_error("shortcut trace mismatch");
  }
}

void TestCurve() {
  P::Sample input;
  input.leftX = 0.5; input.leftY = -0.25;
  input.rightX = 0.5; input.rightY = -0.25;
  const auto state = P::Transform(input);
  Require(state.leftX == 52 && state.leftY == -21, "curve golden values");
  Require(state.rightX == 64 && state.rightY == -32, "C-stick must remain linear");
  Require(std::abs(P::Curve(0.5) - 0.4061261981781178) < 1e-14, "half-stick curve");
  int previous = -128;
  for (int i = -10000; i <= 10000; ++i) {
    const double raw = i / 10000.0;
    const int output = P::Axis(P::Curve(raw));
    Require(output >= previous && output >= -127 && output <= 127, "curve monotonicity/range");
    Require(output == -P::Axis(P::Curve(-raw)), "curve symmetry");
    previous = output;
  }
  Require(P::Axis(P::Curve(1)) == 127 && P::Axis(P::Curve(-1)) == -127, "curve endpoints");
}

void TestThreshold() {
  P::Sample input;
  for (double pressure : {0.0, 0.12, 0.5, 0.5999, 0.599999999}) {
    input.rightTrigger = pressure;
    Require(!P::Transform(input).drift, "trigger activates early");
  }
  for (double pressure : {0.6, 0.600000001, 1.0, 2.0}) {
    input.rightTrigger = pressure;
    const auto state = P::Transform(input);
    Require(state.drift && state.rightTrigger == 255, "threshold/full analog activation");
  }
  input.rightTrigger = 0.5999;
  Require(P::Transform(input).rightTrigger == 153 && !P::Transform(input).drift,
          "byte rounding must not trigger drift");
  input.rightTrigger = 0;
  input.leftTrigger = 0.5999;
  Require(!P::Transform(input).item && !P::Transform(input).drift, "left trigger below 60% must not use item");
  input.leftTrigger = 0.6;
  Require(P::Transform(input).item && !P::Transform(input).drift && P::Transform(input).leftTrigger == 255,
          "left trigger at 60% must use item");
}

void TestButtons() {
  P::Sample input;
  input.leftShoulder = true;
  auto state = P::Transform(input);
  Require(!state.item && state.down && !state.drift && !state.rearView, "L shoulder is Down only");
  input = {}; input.rightShoulder = true;
  state = P::Transform(input);
  Require(state.up && !state.drift && state.rightTrigger == 0, "R shoulder trick without drift");
  input = {}; input.a = input.b = input.x = input.menu = input.left = input.right = true;
  state = P::Transform(input);
  Require(state.accelerate && state.brake && state.rearView && state.pause && state.left && state.right,
          "ordinary mapping");
  input = {}; input.y = true;
  state = P::Transform(input);
  Require(!state.drift && !state.down && !state.rearView && !state.item, "Y must use timed path only");
  state = P::Transform(input, {true, true});
  Require(state.drift && state.down && state.rightTrigger == 255, "shortcut composition");
}

void TestHeldTrace() {
  P::TimedShortcut shortcut;
  Expect(shortcut, false, 0, false, false);
  Expect(shortcut, true, 1000, true, false);
  Expect(shortcut, true, 16666, true, false);
  Expect(shortcut, true, 16667, true, true);
  Expect(shortcut, true, 50999, true, true);
  Expect(shortcut, true, 51000, false, true);
  Expect(shortcut, true, 66666, false, true);
  Expect(shortcut, true, 66667, false, false);
  Expect(shortcut, true, 1000000, false, false);  // no repeat while held
}

void TestShortTapAndRelease() {
  P::TimedShortcut shortcut;
  Expect(shortcut, false, 0, false, false);
  Expect(shortcut, true, 1000, true, false);
  Expect(shortcut, false, 10000, true, false);  // release before hold activates
  Expect(shortcut, false, 17000, true, false);
  Expect(shortcut, false, 51000, false, false);
  Expect(shortcut, true, 52000, true, false);
  Expect(shortcut, true, 67667, true, true);
  Expect(shortcut, false, 68000, true, true);   // an active Down pulse survives release
  Expect(shortcut, false, 117667, false, false);
}

void TestRetriggerExtension() {
  P::TimedShortcut shortcut;
  Expect(shortcut, false, 0, false, false);
  Expect(shortcut, true, 1000, true, false);    // end 51000
  Expect(shortcut, false, 2000, true, false);
  Expect(shortcut, true, 3000, true, false);    // add 50000 -> 101000, not 53000
  Expect(shortcut, false, 4000, true, false);
  Expect(shortcut, false, 53000, true, false);
  Expect(shortcut, false, 101000, false, false);
}

void TestPollingAndReset() {
  P::TimedShortcut shortcut;
  Expect(shortcut, false, 0, false, false);
  // Dolphin hold measures from the last released poll, not a hardware event.
  Expect(shortcut, true, 20000, true, true);
  shortcut.Reset();
  Expect(shortcut, true, 21000, false, false);
  Expect(shortcut, true, 1000000, false, false); // held Y after resume cannot fire
  Expect(shortcut, false, 1001000, false, false);
  Expect(shortcut, true, 1002000, true, false);
  Expect(shortcut, true, 500, false, false);     // clock rollback resets/disarms
  P::TimedShortcut anotherController;
  Expect(anotherController, false, 0, false, false);
  Expect(anotherController, false, 100000, false, false);
}

void TestInvalidInputs() {
  P::Sample input;
  input.leftX = std::numeric_limits<double>::quiet_NaN();
  input.leftY = std::numeric_limits<double>::infinity();
  input.rightTrigger = input.leftX;
  input.leftTrigger = -1;
  const auto state = P::Transform(input);
  Require(state.leftX == 0 && state.leftY == 0 && !state.drift && state.leftTrigger == 0,
          "invalid inputs must be neutral");
  Require(P::Axis(P::Curve(2)) == 127 && P::Axis(P::Curve(-2)) == -127, "out-of-range axes");
}

int main() {
  try {
    TestCurve(); TestThreshold(); TestButtons(); TestHeldTrace();
    TestShortTapAndRelease(); TestRetriggerExtension(); TestPollingAndReset(); TestInvalidInputs();
    std::cout << "PASS: 8 controller-profile test groups, including 20001 curve samples\n";
    return EXIT_SUCCESS;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
