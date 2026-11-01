import AppKit
import Foundation

// Yandex Music: browser-page integration with no OAuth token.
// This is intentionally fail-closed. If the media title/artist, Yandex tab,
// or actual liked flag cannot be verified, the star stays hidden.
// Chrome / Safari require "Allow JavaScript from Apple Events" enabled by user.
enum YandexBrowserFavorites {
    private struct Browser { let bundle: String; let safari: Bool }
    private static let browsers: [Browser] = [
        Browser(bundle: "com.apple.Safari", safari: true),
        Browser(bundle: "com.google.Chrome", safari: false),
        Browser(bundle: "com.google.Chrome.canary", safari: false),
        Browser(bundle: "ru.yandex.desktop.yandex-browser", safari: false),
        Browser(bundle: "ru.yandex.desktop.yandex-browser.beta", safari: false),
        Browser(bundle: "com.brave.Browser", safari: false),
        Browser(bundle: "com.vivaldi.Vivaldi", safari: false),
        Browser(bundle: "org.chromium.Chromium", safari: false)
    ]

    static func verifiesCurrentTrack(_ expected: PlayingTrack) -> Bool {
        perform(expected: expected, target: nil, verifyOnly: true) == "verified"
    }

    static func read(expected: PlayingTrack) -> Bool? {
        switch perform(expected: expected, target: nil) {
        case "liked": return true
        case "not-liked": return false
        default: return nil
        }
    }

    static func write(expected: PlayingTrack, to target: Bool) -> Bool {
        // Never click a button when the original track no longer matches.
        let current = read(expected: expected)
        guard let current else { return false }
        if current == target { return true }
        guard perform(expected: expected, target: target) == "sent" else { return false }
        // The website updates its liked flag asynchronously.
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.25)
            if read(expected: expected) == target { return true }
        }
        return false
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func appleQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func perform(expected: PlayingTrack, target: Bool?, verifyOnly: Bool = false) -> String {
        let javascript = javascriptTemplate
            .replacingOccurrences(of: "__EXPECTED_TITLE__", with: jsonString(expected.title))
            .replacingOccurrences(of: "__EXPECTED_ARTIST__", with: jsonString(expected.artist))
            .replacingOccurrences(of: "__MODE__", with: verifyOnly ? "'verify'" : (target == nil ? "'read'" : "'write'"))
            .replacingOccurrences(of: "__TARGET__", with: target == true ? "true" : "false")
        let permitted = browsers.filter { browser in
            NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundle).isEmpty == false
        }
        // Prefer the source browser when available. Other browsers must
        // still pass the exact-song check in the injected page JavaScript.
        let ordered = permitted.sorted { $0.bundle == expected.sourceBundle && $1.bundle != expected.sourceBundle }
        for browser in ordered {
            let code = appleQuote(javascript)
            let tabCommand = browser.safari ? "do JavaScript \(code) in tabRef" : "execute tabRef javascript \(code)"
            let script = """
            tell application id "\(browser.bundle)"
                repeat with windowRef in windows
                    repeat with tabRef in tabs of windowRef
                        try
                            set pageURL to URL of tabRef
                            if pageURL contains "music.yandex.ru" or pageURL contains "music.yandex.com" then
                                set replyText to \(tabCommand)
                                if replyText is "liked" or replyText is "not-liked" or replyText is "sent" or replyText is "verified" then
                                    return replyText
                                end if
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return "unavailable"
            """
            var error: NSDictionary?
            if let answer = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
               ["liked", "not-liked", "sent", "verified"].contains(answer) { return answer }
        }
        return "unavailable"
    }

    private static let javascriptTemplate = #"""
(function() {
  try {
    if (!/^music\.yandex\.(ru|com)$/i.test(location.hostname)) return "unavailable";
    const clean = (text) => String(text || "").normalize("NFKD")
      .replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase()
      .replace(/[^\p{L}\p{N}]+/gu, " ").trim().replace(/\s+/g, " ");
    const expectedTitle = __EXPECTED_TITLE__;
    const expectedArtist = __EXPECTED_ARTIST__;
    const from = (selectors) => {
      for (const selector of selectors) {
        const node = document.querySelector(selector);
        if (node && node.textContent && node.textContent.trim()) return node.textContent.trim();
      }
      return "";
    };
    const session = navigator.mediaSession && navigator.mediaSession.metadata;
    const domTitle = from([
      ".player-controls__wrapper .track__title", ".player-controls .track__title",
      "[data-test-id='PLAYER_TRACK_TITLE']", "[data-testid='player-track-title']",
      "[class*='PlayerBarDesktop_title']", "[class*='PlayerBarDesktop_trackName']",
      "[class*='PlayerBarDesktop_trackTitle']"
    ]);
    const domArtist = from([
      ".player-controls__wrapper .d-artists", ".player-controls .d-artists",
      "[data-test-id='PLAYER_ARTISTS']", "[data-testid='player-track-artists']",
      "[class*='PlayerBarDesktop_artists']", "[class*='PlayerBarDesktop_artist']"
    ]);
    const valid = (name, artist) => clean(name) === clean(expectedTitle) &&
      clean(artist) === clean(expectedArtist);
    const barSelectors = [
      "[data-test-id='PLAYER_CONTROLS']", "[data-testid='player-bar']",
      "[class*='PlayerBarDesktop']", "[class*='PlayerBar_root']",
      "[class*='player-controls']"
    ];
    // Fallback when a redesigned Yandex player renames its title/artist classes.
    // Require distinct, exactly matching text nodes inside the actual player,
    // not arbitrary links on the rest of the page.
    const barMatch = barSelectors.some(sel => [...document.querySelectorAll(sel)].some(bar => {
      const leaves = [...bar.querySelectorAll('a,span,div')]
        .filter(n => n.children.length === 0 && n.textContent && n.textContent.trim().length < 150)
        .map(n => clean(n.textContent));
      return leaves.includes(clean(expectedTitle)) &&
             leaves.some(n => n === clean(expectedArtist) ||
               n.split(' ').length > 1 && n.includes(clean(expectedArtist)));
    }));
    if (!valid(session && session.title, session && session.artist) &&
        !valid(domTitle, domArtist) && !barMatch) return "mismatch";
    if (__MODE__ === 'verify') return 'verified';

    const candidateSelectors = [
      ".player-controls__track-controls .d-like",
      ".player-controls .d-like",
      "[data-test-id='PLAYER_LIKE_BUTTON']", "[data-testid='player-like-button']",
      "[class*='PlayerBarDesktop_likeButton']", "[class*='PlayerBarDesktop_like'] button",
      "[class*='PlayerBarDesktop'] button[aria-label*='нрав']",
      "[class*='PlayerBarDesktop'] button[aria-label*='коллекц']",
      "[class*='PlayerBarDesktop'] button[title*='нрав']"
    ];
    let button = null;
    for (const selector of candidateSelectors) {
      const node = document.querySelector(selector);
      if (node) { button = node.closest('button,[role=button]') || node; break; }
    }
    if (!button) {
      const roots = document.querySelectorAll("[class*='PlayerBar'],[class*='player-controls'],footer");
      for (const root of roots) {
        for (const node of root.querySelectorAll("button,[role='button']")) {
          const label = ((node.getAttribute('aria-label') || '') + ' ' +
            (node.getAttribute('title') || '')).toLocaleLowerCase();
          if (/не нравится|dislike|не рекомендовать/.test(label)) continue;
          if (/нравит|избран|любим|коллекц|liked|favorite|like track/.test(label)) {
            button = node; break;
          }
        }
        if (button) break;
      }
    }
    if (!button) return "unavailable";
    const status = () => {
      const pressed = button.getAttribute('aria-pressed');
      if (pressed === 'true') return true;
      if (pressed === 'false') return false;
      const dataState = button.getAttribute('data-state');
      if (dataState === 'checked' || dataState === 'active') return true;
      if (dataState === 'unchecked' || dataState === 'inactive') return false;
      const name = String(button.className || '') + ' ' +
        String(button.firstElementChild && button.firstElementChild.className || '');
      if (/d-like_on|likeButton_active|like_active|liked|_liked|_active|_selected/.test(name)) return true;
      const text = ((button.getAttribute('aria-label') || '') + ' ' +
        (button.getAttribute('title') || '')).toLocaleLowerCase();
      if (/убрат|удалит|снять лайк|unlike|remove from/.test(text)) return true;
      if (/добавит|поставит лайк|like this|add to/.test(text)) return false;
      if (/\bd-like\b|\blike-button\b/.test(name)) return false;
      return null;
    };
    const before = status();
    if (before === null) return "unavailable";
    if (__MODE__ === 'read') return before ? 'liked' : 'not-liked';
    if (before !== __TARGET__) button.click();
    return 'sent';
  } catch (_) { return 'unavailable'; }
})()
"""#
}
