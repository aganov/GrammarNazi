# **Release notes** and deployment updates

This paragraph is intentionally long enough to wrap across several lines in the native preview. The text should remain inside the scroll view, leaving the title, tone picker, status, and action buttons visible. **Bold emphasis** and *italic emphasis* should remain readable, and the source view must preserve their original Markdown markers.

## What changed

- The grammar action preserves headings, lists, links, and emphasis.
- The rewrite action improves the wording while retaining the same document structure.
  - Nested items remain nested.
  - A particularly long identifier must wrap: extraordinarily_long_identifier_without_any_spaces_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz.

1. Review the preview.
2. Inspect the Markdown source if needed.
3. Choose **Replace** or **Copy**.

> A quoted sentence keeps its emphasis and remains within the available width.

```swift
let important_identifier_without_breaks = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
print("Code remains unchanged.")
```

Read [the deployment guide](https://example.test/docs/deployment/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz) before continuing.

### Extra content for vertical scrolling

The scroll view must grow its document vertically so this text stays accessible without running behind the buttons. Resizing the window should reflow the paragraph and the long words, while leaving the action area outside the scrolling content.

- Additional item one.
- Additional item two.
- Additional item three.
- Additional item four.
- Additional item five.
