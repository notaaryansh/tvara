import Foundation

extension SearchResult {

    /// Identity used by the frequency reranker to attribute selections.
    /// Derived from `openTarget` so the same conceptual result (e.g. the
    /// Spotify app launched from any rebuild of the app catalog) maps to
    /// a single counter.
    ///
    /// Returns `nil` for source types we deliberately exclude from
    /// frequency tracking:
    ///   - `.systemAction` — destructive (sleep / restart / shutdown);
    ///     habituating these is a foot-gun. Same instinct as the
    ///     no-fuzzy rule in SystemActionsService.
    ///   - `.window` — every selection is contextual to the previously-
    ///     frontmost window; "I usually maximize when I type m" isn't a
    ///     thing worth optimising.
    ///   - `.images` — repeat-rate on a specific image is near zero;
    ///     a per-image counter would just be noise in the DB.
    ///
    /// `nil` is the signal "do not record this selection / do not boost
    /// this result". Callers must handle it.
    var stableId: String? {
        switch source {
        case .systemAction, .window, .images:
            return nil
        default:
            break
        }
        switch openTarget {
        case .url(let s):                       return "url:" + s
        case .file(let p):                      return "file:" + p
        case .whatsappChat(let jid, _):         return "whatsapp:" + jid
        case .imessageChat(let handle, _):      return "imessage:" + handle
        case .copyToClipboard(let s):           return "clip:" + s
        case .notesNote(let title):             return "notes:" + title
        case .spotifyPlay(let uri, _):          return "spotify:" + uri
        case .windowAction, .systemAction:      return nil
        case .imagesCollection:                 return nil
        case .expandSection:                    return nil
        }
    }
}
