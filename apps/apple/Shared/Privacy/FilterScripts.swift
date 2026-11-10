import Foundation
import SetuPrivacyCore

/// The page scripts that carry out the filter rules WebKit's content blocker cannot: scriptlets (in the page's own world, because they must get in front of the page's
/// own code) and procedural cosmetic filters (in the browser's private world). Both are written here, once, and are only ever given the rules as JSON text: nothing from
/// a filter list is joined into code, and a scriptlet can only be one of the few this file implements.
struct FilterScripts: Equatable {
    var page = ""        // scriptlets, run in the page's world at the start of every page and frame
    var cosmetic = ""    // procedural rules, run in the private world
    var isEmpty: Bool { page.isEmpty && cosmetic.isEmpty }

    static func make(from rules: ScriptRuleSet?) -> FilterScripts {
        guard let rules, !rules.isEmpty else { return FilterScripts() }
        var out = FilterScripts()
        let skip = jsonText(rules.exceptions) ?? "[]"
        if !rules.scriptlets.isEmpty, let json = jsonText(rules.scriptlets) { out.page = pageSource.replacingOccurrences(of: "__RULES__", with: json).replacingOccurrences(of: "__EXCEPTIONS__", with: skip) }
        if !rules.procedural.isEmpty, let json = jsonText(rules.procedural) { out.cosmetic = cosmeticSource.replacingOccurrences(of: "__RULES__", with: json).replacingOccurrences(of: "__EXCEPTIONS__", with: skip) }
        return out
    }

    private static func jsonText<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value), var text = String(data: data, encoding: .utf8) else { return nil }
        // JSON may not hold these two characters inside a script string on older engines, and "</script" has no meaning here, but neither belongs in code.
        text = text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return text
    }

    // MARK: Scriptlets (the page's world)

    private static let pageSource = #"""
    (function () {
      var rules = __RULES__, host = location.hostname.toLowerCase();
      function covers(list, h) { return list.some(function (d) { return h === d || h.endsWith('.' + d); }); }
      // A site where blocking is off or paused is left alone, judged by the page the person is on (the top page), also from inside its frames.
      var topHost = host; try { var ao = location.ancestorOrigins; if (ao && ao.length) topHost = new URL(ao[ao.length - 1]).hostname.toLowerCase(); } catch (e) {}
      var skip = __EXCEPTIONS__;
      if (covers(skip, host) || covers(skip, topHost)) return;
      function applies(r) { return (r.domains.length === 0 || covers(r.domains, host)) && !covers(r.excludeDomains, host); }
      var mine = rules.filter(applies);
      if (!mine.length) return;
      var values = { 'undefined': undefined, 'false': false, 'true': true, 'null': null, 'noopFunc': function () {}, 'trueFunc': function () { return true; }, 'falseFunc': function () { return false; },
                     'emptyStr': '', 'emptyArr': [], 'emptyObj': {}, '0': 0, '1': 1, '-1': -1, '': '' };
      function needle(text) {
        if (text && text.length > 2 && text[0] === '/' && text.lastIndexOf('/') > 0) {
          var end = text.lastIndexOf('/');
          try { if (text.length > 200) return null; return new RegExp(text.slice(1, end), text.slice(end + 1).replace(/[^gimsu]/g, '')); } catch (e) { return null; }
        }
        return text;
      }
      function hit(pattern, text) { if (pattern === undefined || pattern === '') return true; if (pattern instanceof RegExp) return pattern.test(text); return String(text).indexOf(pattern) >= 0; }
      function trap(chain, make) {
        var parts = chain.split('.'), owner = window;
        for (var i = 0; i < parts.length - 1; i++) {
          var next = owner[parts[i]];
          if (next === undefined || next === null) {
            // The property does not exist yet: wait for the page to create it, then carry on down the chain.
            (function (obj, name, rest) {
              var held;
              try { Object.defineProperty(obj, name, { configurable: true, get: function () { return held; }, set: function (v) { held = v; try { Object.defineProperty(obj, name, { configurable: true, writable: true, value: v }); } catch (e) {} if (v && typeof v === 'object') trap(rest, make); } }); } catch (e) {}
            })(owner, parts[i], parts.slice(i + 1).join('.'));
            return;
          }
          owner = next;
        }
        try { make(owner, parts[parts.length - 1]); } catch (e) {}
      }
      var run = {
        'set-constant': function (a) {
          var name = a[0], value = a.length > 1 ? values[a[1]] : undefined;
          if (a.length > 1 && !(a[1] in values)) return;
          trap(name, function (obj, prop) { Object.defineProperty(obj, prop, { configurable: true, get: function () { return value; }, set: function () {} }); });
        },
        'abort-on-property-read': function (a) {
          trap(a[0], function (obj, prop) { Object.defineProperty(obj, prop, { configurable: true, get: function () { throw new ReferenceError('bs-abort'); }, set: function () {} }); });
        },
        'abort-on-property-write': function (a) {
          trap(a[0], function (obj, prop) { var v = obj[prop]; Object.defineProperty(obj, prop, { configurable: true, get: function () { return v; }, set: function () { throw new ReferenceError('bs-abort'); } }); });
        },
        'no-setTimeout-if': function (a) { wrapTimer('setTimeout', a); },
        'no-setInterval-if': function (a) { wrapTimer('setInterval', a); },
        'remove-attr': function (a) { whenReady(function () { each(a[1], function (el) { String(a[0]).split('|').forEach(function (n) { el.removeAttribute(n); }); }); }); },
        'remove-class': function (a) { whenReady(function () { each(a[1], function (el) { String(a[0]).split('|').forEach(function (n) { el.classList.remove(n); }); }); }); }
      };
      function wrapTimer(name, a) {
        var original = window[name], pattern = needle(a[0]), delay = a[1] === undefined ? undefined : String(a[1]);
        window[name] = function (callback, ms) {
          try { var text = typeof callback === 'function' ? Function.prototype.toString.call(callback) : String(callback);
                if (hit(pattern, text) && (delay === undefined || delay === '' || String(ms) === delay)) return 0; } catch (e) {}
          return original.apply(this, arguments);
        };
      }
      var pending = [];
      function whenReady(fn) {
        pending.push(fn);
        if (pending.length > 1) return;
        var go = function () { pending.forEach(function (f) { try { f(); } catch (e) {} }); };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go); else go();
        var tries = 0, timer = setInterval(function () { if (++tries > 10) { clearInterval(timer); return; } go(); }, 1000);
      }
      function each(selector, fn) { try { document.querySelectorAll(selector || '*').forEach(fn); } catch (e) {} }
      mine.forEach(function (r) { try { if (run[r.name]) run[r.name](r.args); } catch (e) {} });
    })();
    """#

    // MARK: Procedural cosmetic filters (the private world)

    private static let cosmeticSource = #"""
    (function () {
      var rules = __RULES__, host = location.hostname.toLowerCase();
      function covers(list, h) { return list.some(function (d) { return h === d || h.endsWith('.' + d); }); }
      var topHost = host; try { var ao = location.ancestorOrigins; if (ao && ao.length) topHost = new URL(ao[ao.length - 1]).hostname.toLowerCase(); } catch (e) {}
      var skip = __EXCEPTIONS__;
      if (covers(skip, host) || covers(skip, topHost)) return;
      var mine = rules.filter(function (r) { return (r.domains.length === 0 || covers(r.domains, host)) && !covers(r.excludeDomains, host); });
      if (!mine.length) return;
      var MARK = 'data-bsf-hidden';
      var style = document.createElement('style');
      style.textContent = '[' + MARK + ']{display:none !important}';
      function attach() { (document.head || document.documentElement).appendChild(style); }
      attach();
      function textMatch(arg, text) {
        if (arg.length > 2 && arg[0] === '/' && arg.lastIndexOf('/') > 0) {
          var end = arg.lastIndexOf('/');
          try { return new RegExp(arg.slice(1, end), arg.slice(end + 1).replace(/[^gimsu]/g, '')).test(text); } catch (e) { return false; }
        }
        return text.toLowerCase().indexOf(arg.toLowerCase()) >= 0;
      }
      function cssMatch(arg, el) {
        var i = arg.indexOf(':'); if (i < 0) return false;
        var prop = arg.slice(0, i).trim(), want = arg.slice(i + 1).trim();
        var have = getComputedStyle(el).getPropertyValue(prop);
        if (want.length > 2 && want[0] === '/' && want.lastIndexOf('/') > 0) { try { return new RegExp(want.slice(1, want.lastIndexOf('/'))).test(have); } catch (e) { return false; } }
        var glob = new RegExp('^' + want.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
        return glob.test(have);
      }
      function apply(el, op) {
        if (op.kind === 'has-text') return textMatch(op.arg, el.textContent || '') ? [el] : [];
        if (op.kind === 'matches-css') return cssMatch(op.arg, el) ? [el] : [];
        if (op.kind === 'nth-ancestor') { var n = parseInt(op.arg, 10), p = el; while (n-- > 0 && p) p = p.parentElement; return p ? [p] : []; }
        if (op.kind === 'upward') {
          if (/^\d+$/.test(op.arg)) { var k = parseInt(op.arg, 10), q = el; while (k-- > 0 && q) q = q.parentElement; return q ? [q] : []; }
          try { var c = el.parentElement && el.parentElement.closest(op.arg); return c ? [c] : []; } catch (e) { return []; }
        }
        if (op.kind === 'xpath') {
          var out = [];
          try { var snap = document.evaluate(op.arg, el, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null); for (var i = 0; i < snap.snapshotLength; i++) { if (snap.snapshotItem(i).nodeType === 1) out.push(snap.snapshotItem(i)); } } catch (e) {}
          return out;
        }
        return [];
      }
      function matches(rule) {
        var start;
        if (rule.selector) { try { start = Array.prototype.slice.call(document.querySelectorAll(rule.selector)); } catch (e) { return []; } }
        else start = [document.documentElement];
        rule.ops.forEach(function (op) { var next = []; start.forEach(function (el) { next = next.concat(apply(el, op)); }); start = next; });
        return start;
      }
      var allowedStyle = /^[a-z-]+\s*:\s*[a-z0-9 .,%#!()-]+$/i;
      function act(rule, el) {
        if (!el || el === document.documentElement || el === document.body) return;
        if (rule.action === 'remove') { el.remove(); return; }
        if (rule.action === 'style') { rule.style.split(';').forEach(function (part) { part = part.trim(); if (allowedStyle.test(part)) { var i = part.indexOf(':'); el.style.setProperty(part.slice(0, i).trim(), part.slice(i + 1).replace(/!important/i, '').trim(), 'important'); } }); return; }
        el.setAttribute(MARK, '');
      }
      // Bounded: at most one pass every 400 ms while the page changes, and the passes stop for good after a quiet minute-long burst of 150.
      var passes = 0, waiting = false, last = 0;
      function pass() {
        waiting = false; last = Date.now();
        if (++passes > 150) { try { observer.disconnect(); } catch (e) {} return; }
        mine.forEach(function (rule) { try { matches(rule).forEach(function (el) { act(rule, el); }); } catch (e) {} });
      }
      function schedule() { if (waiting) return; waiting = true; setTimeout(pass, Math.max(0, 400 - (Date.now() - last))); }
      var observer = new MutationObserver(schedule);
      function start() { if (!style.isConnected) attach(); pass(); try { observer.observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {} }
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
    })();
    """#
}
