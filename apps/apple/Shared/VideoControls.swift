import Foundation

/// Playback speed and picture-in-picture for the video on any page. A speed chosen for a website is remembered and applied to every
/// video that site shows afterwards, including ones that appear while you watch. Nothing leaves the device.
enum VideoControls {
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func label(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
    }

    /// Run at the start of every page: gives each video on a remembered site its speed. `speeds` maps a site name (no "www.") to a rate.
    static func rememberedSpeedScript(_ speeds: [String: Double]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: speeds)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return """
        (function () {
          if (window.__bsVideoSpeed) { return; }
          window.__bsVideoSpeed = true;
          var table = \(json), host = location.hostname.toLowerCase().replace(/^www\\./, '');
          var rate = null;
          Object.keys(table).forEach(function (site) { if (host === site || host.endsWith('.' + site)) { rate = table[site]; } });
          if (!rate || !(rate >= 0.0625 && rate <= 16)) { return; }
          function apply(video) { if (video.playbackRate !== rate) { video.playbackRate = rate; } }
          function sweep() { document.querySelectorAll('video').forEach(apply); }
          // A player resets its own speed when a new clip loads, so the speed is put back as each one starts.
          document.addEventListener('loadedmetadata', function (e) { if (e.target && e.target.tagName === 'VIDEO') { apply(e.target); } }, true);
          document.addEventListener('play', function (e) { if (e.target && e.target.tagName === 'VIDEO') { apply(e.target); } }, true);
          document.addEventListener('DOMContentLoaded', sweep);
          sweep();
        })();
        """
    }

    /// Sets the speed of every video on the page now.
    static func setNow(_ rate: Double) -> String {
        "document.querySelectorAll('video').forEach(function (v) { v.playbackRate = \(rate); }); return document.querySelectorAll('video').length;"
    }

    /// Opens the biggest playing (or else the biggest) video in a floating window.
    static let pictureInPicture = """
    var videos = Array.from(document.querySelectorAll('video')).filter(function (v) { return v.readyState > 0; });
    if (!videos.length) { return false; }
    videos.sort(function (a, b) { return (!b.paused - !a.paused) || (b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight); });
    var v = videos[0];
    try {
      if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return true; }
      if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
        v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture'); return true;
      }
      if (v.requestPictureInPicture) { await v.requestPictureInPicture(); return true; }
    } catch (e) { return false; }
    return false;
    """
}
