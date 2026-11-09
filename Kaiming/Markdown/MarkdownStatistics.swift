import Foundation

/// 文档统计。CJK 文本没有空格分词，这里把每个汉字/假名/谚文单独算作一个词，
/// 连续的拉丁字母或数字串算作一个词，标点与空白不计数。
enum MarkdownStatistics {
    /// 可见字符数（按字素簇计），不包含换行符。
    static func characterCount(in text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character != "\n" && character != "\r" {
                count += 1
            }
        }
    }

    /// CJK 感知的词数。
    static func wordCount(in text: String) -> Int {
        var count = 0
        var isInsideLatinWord = false

        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                isInsideLatinWord = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                isInsideLatinWord = false
            } else if CharacterSet.punctuationCharacters.contains(scalar) {
                isInsideLatinWord = false
            } else {
                if !isInsideLatinWord {
                    count += 1
                    isInsideLatinWord = true
                }
            }
        }

        return count
    }

    /// 汉字、日文假名与韩文谚文按单字计数。
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x3040...0x30FF,   // Hiragana + Katakana
             0xAC00...0xD7AF:   // Hangul Syllables
            return true
        default:
            return false
        }
    }
}
