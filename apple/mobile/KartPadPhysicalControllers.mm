#import "KartPadPhysicalControllers.h"
#include "KartPadDolphinProfile.h"

#import "SunPadControllerSlots.h"
#import "SunPadDiagnostics.h"
#import "SunPadInputMixer.h"

#import <GameController/GameController.h>
#import <TargetConditionals.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <vector>

namespace {

namespace Profile = kartpad::mobile::dolphin_profile;
NSString *const kDolphinProfileKey = @"KartPadDolphinXboxProfileV1";

std::int64_t ProfileTimeUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
}

Profile::Sample ProfileSample(const KartPadPhysicalControllerSample& input) {
  Profile::Sample sample;
  sample.a = (input.faceButtons & SunPadPhysicalControllerButtonA) != 0;
  sample.b = (input.faceButtons & SunPadPhysicalControllerButtonB) != 0;
  sample.x = (input.faceButtons & SunPadPhysicalControllerButtonX) != 0;
  sample.y = (input.faceButtons & SunPadPhysicalControllerButtonY) != 0;
  sample.menu = input.menu;
  sample.leftShoulder = (input.faceButtons & SunPadPhysicalControllerButtonLeftShoulder) != 0;
  sample.rightShoulder = input.rightShoulder;
  sample.left = input.dpadLeft;
  sample.right = input.dpadRight;
  sample.leftX = input.leftX;
  sample.leftY = input.leftY;
  sample.rightX = input.rightX;
  sample.rightY = input.rightY;
  sample.leftTrigger = input.leftTrigger;
  sample.rightTrigger = input.rightTrigger;
  return sample;
}

SunPadInputState ProfileState(const Profile::State& input) {
  SunPadInputState state{};
  state.connected = 1;
  state.stickX = input.leftX;
  state.stickY = input.leftY;
  state.cStickX = input.rightX;
  state.cStickY = input.rightY;
  state.triggerL = input.leftTrigger;
  state.triggerR = input.rightTrigger;
  if (input.accelerate) state.buttons |= SunPadButtonA;
  if (input.brake) state.buttons |= SunPadButtonB;
  if (input.rearView) state.buttons |= SunPadButtonX;
  if (input.pause) state.buttons |= SunPadButtonStart;
  if (input.item) state.buttons |= SunPadButtonL;
  if (input.drift) state.buttons |= SunPadButtonR;
  if (input.up) state.buttons |= SunPadButtonDpadUp;
  if (input.down) state.buttons |= SunPadButtonDpadDown;
  if (input.left) state.buttons |= SunPadButtonDpadLeft;
  if (input.right) state.buttons |= SunPadButtonDpadRight;
  return state;
}

uintptr_t ControllerInstanceID(GCController *controller) {
  return reinterpret_cast<uintptr_t>((__bridge void *)controller);
}

GCControllerPlayerIndex PlayerIndexForSlot(const std::size_t slot) {
  switch (slot) {
    case 0: return GCControllerPlayerIndex1;
    case 1: return GCControllerPlayerIndex2;
    case 2: return GCControllerPlayerIndex3;
    case 3: return GCControllerPlayerIndex4;
    default: return GCControllerPlayerIndexUnset;
  }
}

SunPadPhysicalControllerButton PressedFaceButtons(GCExtendedGamepad *pad) {
  uint8_t buttons = 0;
  if (pad.buttonA.isPressed) buttons |= SunPadPhysicalControllerButtonA;
  if (pad.buttonB.isPressed) buttons |= SunPadPhysicalControllerButtonB;
  if (pad.buttonX.isPressed) buttons |= SunPadPhysicalControllerButtonX;
  if (pad.buttonY.isPressed) buttons |= SunPadPhysicalControllerButtonY;
  if (pad.leftShoulder.isPressed) {
    buttons |= SunPadPhysicalControllerButtonLeftShoulder;
  }
  return static_cast<SunPadPhysicalControllerButton>(buttons);
}

KartPadPhysicalControllerSample SampleFromGamepad(GCExtendedGamepad *gamepad) {
  KartPadPhysicalControllerSample sample;
  sample.faceButtons = PressedFaceButtons(gamepad);
  sample.menu = gamepad.buttonMenu.isPressed;
  sample.dpadUp = gamepad.dpad.up.isPressed;
  sample.dpadDown = gamepad.dpad.down.isPressed;
  sample.dpadLeft = gamepad.dpad.left.isPressed;
  sample.dpadRight = gamepad.dpad.right.isPressed;
  sample.rightShoulder = gamepad.rightShoulder.isPressed;
  sample.leftX = gamepad.leftThumbstick.xAxis.value;
  sample.leftY = gamepad.leftThumbstick.yAxis.value;
  sample.rightX = gamepad.rightThumbstick.xAxis.value;
  sample.rightY = gamepad.rightThumbstick.yAxis.value;
  sample.leftTrigger = gamepad.leftTrigger.value;
  sample.rightTrigger = gamepad.rightTrigger.value;
  return sample;
}

// A single Joy-Con (and other small controllers) has no extended profile. Its
// micro profile provides the stick as a direction pad plus A, X and Menu; any
// other buttons appear only in the physical profile under standard names.
BOOL UsesMicroProfile(GCController *controller) {
#if TARGET_OS_TV
  (void)controller;
  return NO;  // The Siri Remote is also a micro gamepad and has its own input path.
#else
  return controller.extendedGamepad == nil && controller.microGamepad != nil;
#endif
}

BOOL IsSupportedController(GCController *controller) {
  return controller.extendedGamepad != nil || UsesMicroProfile(controller);
}

BOOL ProfileButtonPressed(GCPhysicalInputProfile *profile, NSString *name) {
  return profile.buttons[name].isPressed;
}

KartPadPhysicalControllerSample SampleFromMicroGamepad(GCController *controller) {
  GCMicroGamepad *micro = controller.microGamepad;
  GCPhysicalInputProfile *profile = controller.physicalInputProfile;
  KartPadPhysicalControllerSample sample;
  uint8_t buttons = 0;
  if (micro.buttonA.isPressed) buttons |= SunPadPhysicalControllerButtonA;
  if (micro.buttonX.isPressed || ProfileButtonPressed(profile, GCInputButtonB)) {
    buttons |= SunPadPhysicalControllerButtonB;
  }
  if (ProfileButtonPressed(profile, GCInputLeftShoulder) ||
      ProfileButtonPressed(profile, GCInputRightShoulder) ||
      ProfileButtonPressed(profile, GCInputButtonY)) {
    buttons |= SunPadPhysicalControllerButtonLeftShoulder;
  }
  sample.faceButtons = static_cast<SunPadPhysicalControllerButton>(buttons);
  sample.menu = micro.buttonMenu.isPressed ||
      ProfileButtonPressed(profile, GCInputButtonMenu) ||
      ProfileButtonPressed(profile, GCInputButtonOptions);
  sample.dpadUp = micro.dpad.up.isPressed;
  sample.dpadDown = micro.dpad.down.isPressed;
  sample.dpadLeft = micro.dpad.left.isPressed;
  sample.dpadRight = micro.dpad.right.isPressed;
  sample.leftX = micro.dpad.xAxis.value;
  sample.leftY = micro.dpad.yAxis.value;
  return sample;
}

KartPadPhysicalControllerSample SampleFromController(GCController *controller) {
  GCExtendedGamepad *gamepad = controller.extendedGamepad;
  return gamepad != nil ? SampleFromGamepad(gamepad)
                        : SampleFromMicroGamepad(controller);
}

void ClearControllerHandlers(GCController *controller) {
  controller.extendedGamepad.valueChangedHandler = nil;
  if (UsesMicroProfile(controller)) {
    controller.microGamepad.valueChangedHandler = nil;
    controller.physicalInputProfile.valueDidChangeHandler = nil;
  }
}

}  // namespace

SunPadInputState KartPadAdaptPhysicalControllerSample(
    const KartPadPhysicalControllerSample& sample,
    const SunPadControllerButtonMapping mapping) noexcept {
  SunPadInputState state{};
  state.connected = 1;
  uint16_t physical = sample.faceButtons;
  if (sample.dpadUp) physical |= SunPadPhysicalControllerButtonDpadUp;
  if (sample.dpadDown) physical |= SunPadPhysicalControllerButtonDpadDown;
  if (sample.dpadLeft) physical |= SunPadPhysicalControllerButtonDpadLeft;
  if (sample.dpadRight) physical |= SunPadPhysicalControllerButtonDpadRight;
  if (sample.rightShoulder) physical |= SunPadPhysicalControllerButtonRightShoulder;
  if (std::lround(std::clamp(sample.leftTrigger, 0.0f, 1.0f) * 255.0f) > 30) physical |= SunPadPhysicalControllerButtonLeftTrigger;
  if (std::lround(std::clamp(sample.rightTrigger, 0.0f, 1.0f) * 255.0f) > 30) physical |= SunPadPhysicalControllerButtonRightTrigger;
  state.buttons |= SunPadApplyControllerButtonMapping(mapping, (SunPadPhysicalControllerButton)physical);
  if (sample.menu) state.buttons |= SunPadButtonStart;
  state.stickX = static_cast<int8_t>(std::lround(
      std::clamp(sample.leftX, -1.0f, 1.0f) * 127.0f));
  state.stickY = static_cast<int8_t>(std::lround(
      std::clamp(sample.leftY, -1.0f, 1.0f) * 127.0f));
  state.cStickX = static_cast<int8_t>(std::lround(
      std::clamp(sample.rightX, -1.0f, 1.0f) * 127.0f));
  state.cStickY = static_cast<int8_t>(std::lround(
      std::clamp(sample.rightY, -1.0f, 1.0f) * 127.0f));
  state.triggerL = static_cast<uint8_t>(std::lround(
      std::clamp(sample.leftTrigger, 0.0f, 1.0f) * 255.0f));
  const uint8_t physicalTriggerR = static_cast<uint8_t>(std::lround(
      std::clamp(sample.rightTrigger, 0.0f, 1.0f) * 255.0f));
  state.triggerR = SunPadControllerRightTriggerPressure(
      physicalTriggerR, sample.rightShoulder);

  return state;
}

@implementation KartPadPhysicalControllers {
  SunPadControllerSlots _slots;
  NSMutableDictionary<NSNumber *, GCController *> *_configuredControllers;
  std::mutex _stateMutex;
  std::array<SunPadInputState, SunPadControllerSlots::kMaxPlayers> _states;
  std::array<uint16_t, SunPadControllerSlots::kMaxPlayers> _latchedButtons;
  BOOL _started;
  BOOL _dolphinProfileEnabled;
  BOOL _profilePlayerOne;
  Profile::Sample _profileSample;
  Profile::TimedShortcut _shortcut;
}

+ (instancetype)sharedControllers {
  static KartPadPhysicalControllers *controllers = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    controllers = [[KartPadPhysicalControllers alloc] init];
  });
  return controllers;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _configuredControllers = [NSMutableDictionary dictionary];
    _states = {};
    _latchedButtons = {};
    _dolphinProfileEnabled = [NSUserDefaults.standardUserDefaults boolForKey:kDolphinProfileKey];
  }
  return self;
}

- (void)start {
  if (_started) return;
  _started = YES;
  NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
  [notifications addObserver:self
                    selector:@selector(controllerConnectionChanged:)
                        name:GCControllerDidConnectNotification
                      object:nil];
  [notifications addObserver:self
                    selector:@selector(controllerConnectionChanged:)
                        name:GCControllerDidDisconnectNotification
                      object:nil];
  [self reconcileControllers];
}

- (void)stop {
  if (!_started) return;
  _started = NO;
  [NSNotificationCenter.defaultCenter removeObserver:self];
  for (GCController *controller in _configuredControllers.allValues) {
    ClearControllerHandlers(controller);
    controller.playerIndex = GCControllerPlayerIndexUnset;
  }
  [_configuredControllers removeAllObjects];
  _slots = {};
  {
    std::scoped_lock lock(_stateMutex);
    _states = {};
    _latchedButtons = {};
    _profilePlayerOne = NO;
    _profileSample = {};
    _shortcut.Reset();
  }
  [[SunPadInputMixer sharedMixer] clearInputFromTouch:NO];
}

- (void)controllerConnectionChanged:(NSNotification *)notification {
  (void)notification;
  [self reconcileControllers];
}

- (void)publishController:(GCController *)controller {
  const int slot = _slots.SlotFor(ControllerInstanceID(controller));
  if (slot < 0 || slot >= static_cast<int>(SunPadControllerSlots::kMaxPlayers)) {
    return;
  }
  const auto sample = SampleFromController(controller);
  SunPadInputState state = KartPadAdaptPhysicalControllerSample(
      sample, [SunPadControllerMappingStore mapping]);
  BOOL profile = NO;
  if (UsesMicroProfile(controller) && (state.buttons != 0 || state.stickX != 0 || state.stickY != 0)) {
    static std::atomic<int> logged{0};
    if (logged.fetch_add(1, std::memory_order_relaxed) < 12) {
      SunPadLog(@"micro controller input slot=%d buttons=0x%04x stick=%d,%d", slot + 1,
                state.buttons, state.stickX, state.stickY);
    }
  }
  {
    std::scoped_lock lock(_stateMutex);
    const std::size_t index = static_cast<std::size_t>(slot);
    profile = slot == 0 && _dolphinProfileEnabled && controller.extendedGamepad != nil;
    if (slot == 0) {
      if (profile != _profilePlayerOne) _shortcut.Reset();
      _profilePlayerOne = profile;
      if (profile) {
        _profileSample = ProfileSample(sample);
        // Only ordinary buttons latch at event time. Timed Y expressions run
        // at input polls, including polls where the controller has no events.
        state = ProfileState(Profile::Transform(_profileSample));
      }
    }
    _latchedButtons[index] |= state.buttons & ~_states[index].buttons;
    _states[index] = state;
  }
  if (slot == 0 && !profile) {
    [[SunPadInputMixer sharedMixer] setInputState:state fromTouch:NO];
  }
}

- (void)configureController:(GCController *)controller
                       slot:(const std::size_t)slot {
  if (!IsSupportedController(controller)) return;
  controller.handlerQueue = dispatch_get_main_queue();
  __weak KartPadPhysicalControllers *weakSelf = self;
  __weak GCController *weakController = controller;
  // Sample inside the event callback. Deferring the read again can turn a
  // quick press/release into two released samples before the game polls.
  void (^publish)(void) = ^{
    KartPadPhysicalControllers *strongSelf = weakSelf;
    GCController *strongController = weakController;
    if (strongSelf != nil && strongController != nil) {
      [strongSelf publishController:strongController];
    }
  };
  if (GCExtendedGamepad *gamepad = controller.extendedGamepad) {
    gamepad.valueChangedHandler = ^(GCExtendedGamepad *, GCControllerElement *) {
      publish();
    };
  } else {
    // A single Joy-Con reports through its micro profile. Listen on both that
    // profile and the physical profile: iOS does not guarantee the physical
    // profile's handler fires for every micro controller, and publishing twice
    // is harmless because each publish reads the complete current state.
    controller.microGamepad.valueChangedHandler = ^(GCMicroGamepad *, GCControllerElement *) {
      publish();
    };
    controller.physicalInputProfile.valueDidChangeHandler =
        ^(GCPhysicalInputProfile *, GCControllerElement *) {
          publish();
        };
    NSArray<NSString *> *buttons =
        [controller.physicalInputProfile.buttons.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSString *> *dpads =
        [controller.physicalInputProfile.dpads.allKeys sortedArrayUsingSelector:@selector(compare:)];
    SunPadLog(@"micro controller vendor=%@ category=%@ buttons=%@ dpads=%@",
              controller.vendorName ?: @"unknown", controller.productCategory ?: @"unknown",
              [buttons componentsJoinedByString:@","], [dpads componentsJoinedByString:@","]);
  }
  controller.playerIndex = PlayerIndexForSlot(slot);
  [self publishController:controller];
}

- (void)reconcileControllers {
  [self reconcileControllerList:GCController.controllers];
}

- (void)reconcileControllerList:(NSArray<GCController *> *)controllers {
  std::vector<uintptr_t> instances;
  for (GCController *controller in controllers) {
    if (IsSupportedController(controller)) {
      instances.push_back(ControllerInstanceID(controller));
    }
  }

  const SunPadControllerReconcileResult result = _slots.Reconcile(instances);
  for (const SunPadControllerSlotChange& change : result.removed) {
    NSNumber *key = @(change.instance);
    GCController *controller = _configuredControllers[key];
    ClearControllerHandlers(controller);
    controller.playerIndex = GCControllerPlayerIndexUnset;
    [_configuredControllers removeObjectForKey:key];
    {
      std::scoped_lock lock(_stateMutex);
      _states[change.slot] = {};
      _latchedButtons[change.slot] = 0;
      if (change.slot == 0) {
        _profilePlayerOne = NO;
        _profileSample = {};
        _shortcut.Reset();
      }
    }
    if (change.slot == 0) {
      [[SunPadInputMixer sharedMixer] clearInputFromTouch:NO];
    }
    SunPadLog(@"controller removed slot=%lu", (unsigned long)change.slot + 1);
  }

  for (GCController *controller in controllers) {
    if (!IsSupportedController(controller)) continue;
    const uintptr_t instance = ControllerInstanceID(controller);
    const int slot = _slots.SlotFor(instance);
    if (slot < 0) continue;
    NSNumber *key = @(instance);
    if (_configuredControllers[key] != controller) {
      _configuredControllers[key] = controller;
      [self configureController:controller slot:static_cast<std::size_t>(slot)];
      SunPadLog(@"controller assigned slot=%d vendor=%@", slot + 1,
                controller.vendorName != nil ? controller.vendorName : @"unknown");
    }
  }
}

- (BOOL)consumePlayer:(NSUInteger)player state:(SunPadInputState *)state {
  if (state == nullptr || player >= SunPadControllerSlots::kMaxPlayers) {
    return NO;
  }
  std::scoped_lock lock(_stateMutex);
  *state = _states[player];
  if (player == 0 && _profilePlayerOne) {
    *state = ProfileState(Profile::Transform(
        _profileSample, _shortcut.Poll(_profileSample.y, ProfileTimeUs())));
  }
  state->buttons |= _latchedButtons[player];
  _latchedButtons[player] = 0;
  return state->connected != 0;
}

- (SunPadInputState)consumeMergedPlayerOne {
  std::scoped_lock lock(_stateMutex);
  if (_profilePlayerOne) {
    auto state = ProfileState(Profile::Transform(
        _profileSample, _shortcut.Poll(_profileSample.y, ProfileTimeUs())));
    state.buttons |= _latchedButtons[0];
    _latchedButtons[0] = 0;
    [[SunPadInputMixer sharedMixer] setInputState:state fromTouch:NO];
  }
  return [[SunPadInputMixer sharedMixer] consumeMergedState];
}

- (BOOL)isDolphinProfileEnabled {
  std::scoped_lock lock(_stateMutex);
  return _dolphinProfileEnabled;
}

- (void)setDolphinProfileEnabled:(BOOL)enabled {
  NSAssert(NSThread.isMainThread, @"Controller preset changes require the main thread");
  [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kDolphinProfileKey];
  {
    std::scoped_lock lock(_stateMutex);
    _dolphinProfileEnabled = enabled;
    _profilePlayerOne = NO;
    _profileSample = {};
    _shortcut.Reset();
    _states[0] = {};
    _latchedButtons[0] = 0;
    [[SunPadInputMixer sharedMixer] clearInputFromTouch:NO];
  }
  for (GCController *controller in _configuredControllers.allValues) {
    [self publishController:controller];
  }
}

- (void)resetDolphinShortcut {
  std::scoped_lock lock(_stateMutex);
  _shortcut.Reset();
  if (_profilePlayerOne) {
    _latchedButtons[0] = 0;
    [[SunPadInputMixer sharedMixer] clearInputFromTouch:NO];
  }
}

- (BOOL)isPlayerConnected:(NSUInteger)player {
  if (player >= SunPadControllerSlots::kMaxPlayers) return NO;
  std::scoped_lock lock(_stateMutex);
  return _states[player].connected != 0;
}

- (NSArray<NSString *> *)playerDescriptions {
  NSAssert(NSThread.isMainThread, @"Controller descriptions require the main thread");
  NSMutableArray<NSString *> *players = [NSMutableArray array];
  for (std::size_t slot = 0; slot < SunPadControllerSlots::kMaxPlayers; ++slot) {
    GCController *controller = _configuredControllers[@(_slots.InstanceAt(slot))];
    NSString *name = controller.vendorName ?: @"Controller";
    [players addObject:[NSString stringWithFormat:@"Player %lu: %@",
        (unsigned long)slot + 1, controller ? name : @"Not connected"]];
  }
  return players;
}

- (NSUInteger)connectedControllerCount {
  std::scoped_lock lock(_stateMutex);
  NSUInteger count = 0;
  for (const SunPadInputState& state : _states) {
    if (state.connected != 0) ++count;
  }
  return count;
}

@end
