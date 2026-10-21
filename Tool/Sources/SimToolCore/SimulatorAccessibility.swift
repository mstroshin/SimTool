import CryptoKit
import Foundation

/// An accessibility setting `simctl ui` has no verb for.
public enum SimulatorAccessibilitySetting: String, CaseIterable, Codable, Sendable {
    case reduceMotion = "reduce-motion"
    case reduceTransparency = "reduce-transparency"
    case buttonShapes = "button-shapes"
    case voiceOver = "voiceover"
    case colorFilter = "color-filter"
    case liquidGlass = "liquid-glass"

    public var title: String {
        switch self {
        case .reduceMotion: "Reduce Motion"
        case .reduceTransparency: "Reduce Transparency"
        case .buttonShapes: "Button Shapes"
        case .voiceOver: "VoiceOver"
        case .colorFilter: "Color Filters"
        case .liquidGlass: "Liquid Glass"
        }
    }

    /// The values it takes; nil for a switch, which takes on or off.
    public var values: [String]? {
        switch self {
        case .colorFilter: ["none", "grayscale", "protanopia", "deuteranopia", "tritanopia"]
        case .liquidGlass: ["clear", "tinted"]
        default: nil
        }
    }

    public init?(parsing raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        if let setting = Self(rawValue: name) { self = setting; return }
        switch name {
        case "reducemotion", "motion": self = .reduceMotion
        case "reducetransparency", "transparency": self = .reduceTransparency
        case "buttonshapes", "shapes": self = .buttonShapes
        case "voice-over": self = .voiceOver
        case "colorfilter", "color-filters", "filter": self = .colorFilter
        case "liquidglass", "glass": self = .liquidGlass
        default: return nil
        }
    }

    /// A value it takes, normalised: a filter's other names
    /// (`red-green` is protanopia), on/off for a switch.
    public func value(parsing raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch self {
        case .colorFilter:
            switch value {
            case "off": return "none"
            case "gray", "greyscale": return "grayscale"
            case "red-green", "redgreen": return "protanopia"
            case "green-red", "greenred": return "deuteranopia"
            case "blue-yellow", "blueyellow": return "tritanopia"
            default: return values?.contains(value) == true ? value : nil
            }
        case .liquidGlass:
            return values?.contains(value) == true ? value : nil
        default:
            switch value {
            case "on", "true", "yes", "1", "enabled": return "on"
            case "off", "false", "no", "0", "disabled": return "off"
            default: return nil
            }
        }
    }

    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// The accessibility settings as the device reports them; a setting the
/// runtime does not have is absent (Liquid Glass before iOS 26).
public struct SimulatorAccessibilitySettings: Codable, Equatable, Sendable {
    public var reduceMotion: Bool?
    public var reduceTransparency: Bool?
    public var buttonShapes: Bool?
    public var voiceOver: Bool?
    /// none, grayscale, protanopia, deuteranopia, tritanopia.
    public var colorFilter: String?
    /// clear, tinted.
    public var liquidGlass: String?

    public init(reduceMotion: Bool? = nil, reduceTransparency: Bool? = nil, buttonShapes: Bool? = nil, voiceOver: Bool? = nil, colorFilter: String? = nil, liquidGlass: String? = nil) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.buttonShapes = buttonShapes
        self.voiceOver = voiceOver
        self.colorFilter = colorFilter
        self.liquidGlass = liquidGlass
    }

    /// The setting's value in the words the CLI takes: on, off, a filter, a glass.
    public func value(of setting: SimulatorAccessibilitySetting) -> String? {
        func onOff(_ value: Bool?) -> String? { value.map { $0 ? "on" : "off" } }
        switch setting {
        case .reduceMotion: return onOff(reduceMotion)
        case .reduceTransparency: return onOff(reduceTransparency)
        case .buttonShapes: return onOff(buttonShapes)
        case .voiceOver: return onOff(voiceOver)
        case .colorFilter: return colorFilter
        case .liquidGlass: return liquidGlass
        }
    }
}

/// Reads and changes them through a helper SimTool runs inside the simulator
/// (`simctl spawn`): the guest's own libAccessibility setters, the ones
/// Settings calls — they store the preference and post the notification
/// running apps listen for, so an app follows at once.
public enum SimulatorAccessibilitySettingsClient {
    private static let helperVersion = "1"
    private static let helperFingerprint = SHA256.hash(data: Data(SimulatorAccessibilityHelperSource.source.utf8))
        .prefix(6).map { String(format: "%02x", $0) }.joined()

    public static func read(deviceUDID: String) async throws -> SimulatorAccessibilitySettings {
        try await run(["status"], deviceUDID: deviceUDID)
    }

    /// Changes one setting and returns all of them as the device has them after.
    public static func set(_ setting: SimulatorAccessibilitySetting, to raw: String, deviceUDID: String) async throws -> SimulatorAccessibilitySettings {
        guard let value = setting.value(parsing: raw) else {
            throw SimToolError("\(setting.title) takes \(setting.values?.joined(separator: ", ") ?? "on or off"), not \(raw)")
        }
        return try await run(["set", setting.rawValue, value], deviceUDID: deviceUDID)
    }

    private static func run(_ arguments: [String], deviceUDID: String) async throws -> SimulatorAccessibilitySettings {
        let helper = try await helperURL()
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "spawn", deviceUDID, helper.path] + arguments,
            timeoutSeconds: 15
        )
        guard output.status == 0 else {
            let detail = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimToolError(detail.isEmpty ? "The accessibility helper failed (exit \(output.status))" : detail)
        }
        do {
            return try JSONDecoder().decode(SimulatorAccessibilitySettings.self, from: output.stdout)
        } catch {
            throw SimToolError("The accessibility helper answered something else: \(output.stdoutString)")
        }
    }

    /// Built for the simulator once per helper source, ad-hoc signed — `simctl
    /// spawn` runs nothing unsigned — and cached next to the other helpers.
    /// Several processes may build it at once: each writes its own files and
    /// renames the result into place.
    private static func helperURL() async throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw SimToolError("Failed to locate user caches directory")
        }
        let directory = caches.appendingPathComponent("SimTool/SimulatorHelpers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let output = directory.appendingPathComponent("simtool-accessibility-\(helperVersion)-\(helperFingerprint)-\(arch)")
        if FileManager.default.isExecutableFile(atPath: output.path) { return output }
        let unique = UUID().uuidString
        let source = directory.appendingPathComponent("\(output.lastPathComponent).\(unique).m")
        let temporary = directory.appendingPathComponent("\(output.lastPathComponent).tmp.\(unique)")
        try SimulatorAccessibilityHelperSource.source.write(to: source, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: temporary)
        }
        let built = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", "iphonesimulator", "clang", "-arch", arch, "-mios-simulator-version-min=15.0", "-fobjc-arc",
                        "-framework", "Foundation", "-Wl,-adhoc_codesign", "-o", temporary.path, source.path],
            timeoutSeconds: 60
        )
        guard built.status == 0 else {
            throw SimToolError(built.stderrString.isEmpty ? "Failed to build the accessibility helper" : built.stderrString)
        }
        guard rename(temporary.path, output.path) == 0 else {
            throw SimToolError("Failed to install the accessibility helper: \(String(cString: strerror(errno)))")
        }
        return output
    }
}

enum SimulatorAccessibilityHelperSource {
    static let source = #"""
    #import <Foundation/Foundation.h>
    #import <dlfcn.h>
    #import <notify.h>
    #import <stdio.h>
    #import <string.h>

    // Runs inside the simulator (simctl spawn) and reads or changes the
    // accessibility settings simctl has no verb for, through libAccessibility's
    // own setters — what Settings calls; each stores the preference and posts
    // the notification apps listen for.
    //
    //   status               prints every setting as one JSON object
    //   set KEY VALUE        changes one, then prints them all
    //
    //   reduce-motion, reduce-transparency, button-shapes, voiceover   on | off
    //   color-filter   none | grayscale | protanopia | deuteranopia | tritanopia
    //   liquid-glass   clear | tinted   (iOS 26 and later)

    typedef int (*Get)(void);
    typedef void (*Set)(int);

    typedef struct { const char *key, *json, *getter, *setter; } Setting;

    static const Setting switches[] = {
      {"reduce-motion", "reduceMotion", "_AXSReduceMotionEnabled", "_AXSSetReduceMotionEnabled"},
      {"reduce-transparency", "reduceTransparency", "_AXSEnhanceBackgroundContrastEnabled", "_AXSSetEnhanceBackgroundContrastEnabled"},
      {"button-shapes", "buttonShapes", "_AXSButtonShapesEnabled", "_AXSSetButtonShapesEnabled"},
      {"voiceover", "voiceOver", "_AXSVoiceOverTouchEnabled", "_AXSVoiceOverTouchSetEnabled"},
    };

    // Settings › Accessibility › Display & Text Size › Color Filters: one at a time.
    static const Setting filters[] = {
      {"grayscale", NULL, "_AXSGrayscaleEnabled", "_AXSGrayscaleSetEnabled"},
      {"protanopia", NULL, "_AXSRedGreenFilterEnabled", "_AXSRedGreenFilterSetEnabled"},
      {"deuteranopia", NULL, "_AXSGreenRedFilterEnabled", "_AXSGreenRedFilterSetEnabled"},
      {"tritanopia", NULL, "_AXSBlueYellowFilterEnabled", "_AXSBlueYellowFilterSetEnabled"},
    };
    static const int switchCount = sizeof(switches) / sizeof(switches[0]);
    static const int filterCount = sizeof(filters) / sizeof(filters[0]);

    static void *library(void) {
      static void *handle;
      if (!handle) { handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW); }
      return handle;
    }

    static void *symbol(const char *name) { return library() ? dlsym(library(), name) : NULL; }

    // iOS 26 added Liquid Glass and, in 26.1, the choice of how it reads.
    static BOOL hasLiquidGlass(void) { return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26; }
    static CFStringRef glassDomain = CFSTR("com.apple.UIKit");
    static CFStringRef glassKey = CFSTR("UIViewGlassLegibilitySetting");

    static const char *glass(void) {
      CFPropertyListRef value = CFPreferencesCopyValue(glassKey, glassDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
      int tinted = 0;
      if (value && CFGetTypeID(value) == CFNumberGetTypeID()) { CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &tinted); }
      if (value) { CFRelease(value); }
      return tinted == 1 ? "tinted" : "clear";
    }

    static void setGlass(BOOL tinted) {
      int number = tinted ? 1 : 0;
      CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &number);
      CFPreferencesSetValue(glassKey, value, glassDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
      CFRelease(value);
      CFPreferencesSynchronize(glassDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
      notify_post("UIViewGlassLegibilityUpdateNotification");
    }

    // A setting the runtime lacks is left out of the object.
    static void status(void) {
      const char *separator = "";
      printf("{");
      for (int i = 0; i < switchCount; i++) {
        Get get = symbol(switches[i].getter);
        if (get) { printf("%s\"%s\":%s", separator, switches[i].json, get() ? "true" : "false"); separator = ","; }
      }
      const char *filter = "none";
      BOOL known = YES;
      for (int i = 0; i < filterCount; i++) {
        Get get = symbol(filters[i].getter);
        if (!get) { known = NO; } else if (get()) { filter = filters[i].key; }
      }
      if (known) { printf("%s\"colorFilter\":\"%s\"", separator, filter); separator = ","; }
      if (hasLiquidGlass()) { printf("%s\"liquidGlass\":\"%s\"", separator, glass()); }
      printf("}\n");
    }

    static int fail(const char *message, const char *detail) {
      fprintf(stderr, "%s%s\n", message, detail ?: "");
      return 2;
    }

    int main(int argc, const char *argv[]) {
      @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "status")) { status(); return 0; }
        if (argc != 4 || strcmp(argv[1], "set")) { return fail("usage: status | set KEY VALUE", NULL); }
        const char *key = argv[2], *value = argv[3];
        for (int i = 0; i < switchCount; i++) {
          if (strcmp(key, switches[i].key)) { continue; }
          Set set = symbol(switches[i].setter);
          if (!set) { return fail("this runtime has no setter for ", key); }
          if (strcmp(value, "on") && strcmp(value, "off")) { return fail("takes on or off: ", key); }
          set(!strcmp(value, "on"));
          status();
          return 0;
        }
        if (!strcmp(key, "color-filter")) {
          int chosen = -1;
          for (int i = 0; i < filterCount; i++) { if (!strcmp(value, filters[i].key)) { chosen = i; } }
          if (chosen < 0 && strcmp(value, "none")) { return fail("unknown color filter ", value); }
          for (int i = 0; i < filterCount; i++) {
            Set set = symbol(filters[i].setter);
            Get get = symbol(filters[i].getter);
            if (!set || !get) { return fail("this runtime has no color filter ", filters[i].key); }
            if (i != chosen && get()) { set(0); }
          }
          if (chosen >= 0) { ((Set)symbol(filters[chosen].setter))(1); }
          status();
          return 0;
        }
        if (!strcmp(key, "liquid-glass")) {
          if (!hasLiquidGlass()) { return fail("Liquid Glass needs iOS 26 or later", NULL); }
          if (strcmp(value, "clear") && strcmp(value, "tinted")) { return fail("takes clear or tinted: ", key); }
          setGlass(!strcmp(value, "tinted"));
          status();
          return 0;
        }
        return fail("unknown setting ", key);
      }
    }
    """#
}
