// The text box's lines from OCR readings (ShownLines.note): new lines, lines that grew, read again or misread, rows that
// scroll out. A golden test: the cases' results are compared with Fixtures/shown-lines.txt (UPDATE_GOLDEN=1 swift test
// writes it again after a change that's meant to change them; check the diff).
import Foundation
import Testing
@testable import MacPopup

@Test func shownLinesCases() throws {
    var output = ""
    func out(_ line: String) { output += line + "\n" }
    var lines = ShownLines<Int>()
    func note(_ t: String, page: Bool = true, breaks: Set<Int> = [], rows: [String] = [], letters: [CGRect] = []) {
        let r = lines.note(t, page: page, breaks: breaks, rows: rows, letters: letters, info: { 0 })
        out(String(format: "%-46@ -> %@   [%@]", t as NSString, String(describing: r!) as NSString,
                   lines.map { $0.text }.joined(separator: " | ") as NSString))
    }
    func rows(_ r: [String]) { note(r.joined(), rows: r) }

    out("— NVL page, Japanese")
    note("「おはよう。」")
    note("「おはよう。」「今日は早いね、")                 // after a sentence: new line
    note("「おはよう。」「今日は早いね、どうしたの？」")     // the line goes on: grew
    note("「おはよう。」「今日は早いね、どうしたの？」")     // read again
    note("「おはよう。」「今日は早いね、とうしたの？」")     // misread again
    note("「おはよう。」「今日は早いね、どうしたの？」……」", breaks: [])
    out("— paragraph break without punctuation (from the rows)")
    note("……誰もいない")
    note("……誰もいない扉の向こう", breaks: [7])
    out("— at once: one line")
    note("こんにちは。元気？今日もいい天気だね。")
    out("— English")
    note("Hello there.")
    note("Hello there. How are you")
    note("Hello there. How are you doing today?")
    note("Mr. Smith went")
    note("Mr. Smith went home.")
    out("— hooked lines don't split")
    note("こんにちは。", page: false)
    note("こんにちは。元気？", page: false)
    out("— misreads earlier on the page (novel1)")
    lines = ShownLines<Int>()
    note("「うん、ちょっと用事があって……………」")
    note("「うん、ちょっと用事があって…………」そう言って彼女は", breaks: [17])
    note("「うん、ちょっと用事があって……………」そう言って彼女は笑った。", breaks: [18])
    note("「うん、ちょっと用事があって…………」そう言って彼女は笑った。それから、", breaks: [17, 29])
    note("「うん、ちょっと用事があって……………」そう言って彼女は笑った。それから、駅へ向かった。", breaks: [18, 30])
    out("— a late hooked line in the middle of a page")
    lines = ShownLines<Int>()
    note("一行目です。")
    note("一行目です。二行目です。")
    note("二行目です。", page: false)
    note("一行目です。二行目です。三行目です。")
    note("別の行。", page: false)
    note("一行目です。二行目です。三行目です。四行目です。")
    out("— a row break after a comma (intro)")
    lines = ShownLines<Int>()
    note("それなのにいったい誰が、")
    note("それなのにいったい誰が、この身体の中に", breaks: [11])
    note("それなのにいったい誰が、この身体の中に僕の心があるって言い切れるんだ?", breaks: [11])
    note("それなのにいったい誰が、この身体の中に僕の心があるって言い切れるんだ?でも", breaks: [11, 35])
    out("— a dash appears before the line (intro)")
    lines = ShownLines<Int>()
    note("僕を、")
    note("―僕を、")
    note("―僕を、見るな。")
    note("―僕を、見るな。誰も", breaks: [8])
    out("— dots that come and go (Umineko)")
    lines = ShownLines<Int>()
    note("「忠告の気持ちだけはありがたくいただいておく。我が友よ。")
    note("「忠告の気持ちだけはありがたくいただいておく。我が友よ。源次。")
    note("「忠告の気持ちだけはありがたくいただいておく。我が友よ。…･…源次。")
    note("「忠告の気持ちだけはありがたくいただいておく。我が友よ。……源次。もう一杯頼む。")
    note("「忠告の気持ちだけはありがたくいただいておく。我が友よ。源次。もう一杯頼む。")
    note("「忠告の気持ちだけはありがたくいただいておく。我が友よ。………源次。もう一杯頼む。心持ち薄めでな。")
    out("— a text box that scrolls: its first row goes out at the top (Umineko PS3)")
    lines = ShownLines<Int>()
    rows(["「………………………それを書き記せばいい。もちろん、生きている内", "にこなせればそれでいい。"])
    rows(["「………………………それを書き記せばいい。もちろん、生きている内", "にこなせればそれでいい。だが万一の時、残された者がそ", "れを引き継いでくれる。"])
    rows(["「………………………それを書き記せばいい。もちろん、生きている内", "にこなせればそれでいい。だが万一の時、残された者がそ", "れを引き継いでくれる。自分に万一があっても、必ずその", "心残りが解決できるように残していく。▶"])
    rows(["にこなせればそれでいい。だが万一の時、残された者がそ", "れを引き継いでくれる。自分に万一があっても、必ずその", "心残りが解決できるように残していく。………………それが遺言と", "いうものです」▼"])
    rows(["にこなせればそれでいい。だが万一の時、残された者がそ", "れを引き継いでくれる。自分に万一があっても、必ずその", "心残りが解決できるように残していく。………………それが遺言と", "いうものです」▼"])
    out("— within a sentence, and two rows at once")
    rows(["「私が生きている内でなくてはならぬ、私は死ねば魂はす", "ぐに契約の悪魔に食らわれて消え去ってしまう!▶"])
    rows(["「私が生きている内でなくてはならぬ、私は死ねば魂はす", "ぐに契約の悪魔に食らわれて消え去ってしまう! 死後の", "世界も安らぎも私にはないのだ!▶"])
    rows(["「私が生きている内でなくてはならぬ、私は死ねば魂はす", "ぐに契約の悪魔に食らわれて消え去ってしまう! 死後の", "世界も安らぎも私にはないのだ! だから全ては私が生き", "ている内でなければならぬ!!▶"])
    rows(["世界も安らぎも私にはないのだ! だから全ては私が生き", "ている内でなければならぬ!! だから遺言状など私には", "必要ないッ!!」▼"])
    out("— a new page that starts like a row of the old one isn't taken for it scrolled")
    rows(["そこにあるのは、崩壊した街", "そこにあるのは、絶望"])
    rows(["そこにあるのは、絶望の色。"])
    out("— an opening bracket read late, with fewer dots (Umineko PS3)")
    lines = ShownLines<Int>()
    note("……………………心残りや、遣り残し。")
    note("「…………心残りや、遣り残し。")
    note("「…………･心残りや、遣り残し。受け継いで欲しいことや、", breaks: [])
    note("「…………………心残りや、遣り残し。受け継いで欲しいことや、………………伝えたいこと。▶")
    out("— a scroll that adds little (would pass for the page read again)")
    lines = ShownLines<Int>()
    rows(["「一行目の文です。二行目に続", "く文です。"])
    rows(["「一行目の文です。二行目に続", "く文です。三行目の文で", "す。四行目の文です。"])
    rows(["く文です。三行目の文で", "す。四行目の文です。", "はい。"])
    out("— a name tag row as the old page's last line, then a new page starting with it")
    lines = ShownLines<Int>()
    rows(["「くっくっく。そうかい。」"])
    rows(["「くっくっく。そうかい。」", "【ベアトリーチェ】「……」"])
    rows(["【ベアトリーチェ】「……くっくっく。」"])
    out("— the next line's dots read as periods after a sentence end (Live Text, PS3 Umineko)")
    lines = ShownLines<Int>()
    note("だが、そんな強い酒を飲み続けては薬の意味もなくなってしまう。")
    note("だが、そんな強い酒を飲み続けては薬の意味もなくなってしまう。..・悪いことは言わん。")   // new line
    note("我が友よ。")
    note("我が友よ。.......・・源次。")                                                     // new line
    note("そのようなものを書く暇があったなら、あったならッ！！...私は見たい。", breaks: [])     // at once: one line
    out("— periods then a letter: Unicode ends a sentence there anyway (before the fix too)")
    lines = ShownLines<Int>()
    note("そうだな...")
    note("そうだな...それでいい。")                                                       // new line
    out("— a short line that ends the last one, after the box was empty (Somnium): dots don't make it long")
    lines = ShownLines<Int>()
    note("そしておまえは…")
    note("おまえは…")                                                                      // new line
    out("— the same letters in the same places, marks read differently (a blinking icon read as a bracket, Phantom of Inferno)")
    lines = ShownLines<Int>()
    let row = { (xs: [CGFloat]) in xs.map { CGRect(x: $0, y: 584, width: 50, height: 42) } }
    note("………………殺される･……………』", letters: row([244, 298, 344, 399]))
    note("………………殺される･……………」", letters: row([246, 297, 345, 401]))                  // again
    note("……………･殺される……………", letters: row([244, 298, 344, 399]))                    // again
    note("………………殺される･……………』", letters: row([244, 298, 344, 399]))                  // again
    out("— the same letters elsewhere, other letters, or no letters: new lines")
    note("………………殺される･……………」", letters: row([544, 598, 644, 699]))                  // new line
    note("………………殺されろ･……………」", letters: row([544, 598, 644, 699]))                  // new line
    note("……！")
    note("……？")                                                                           // new line
    out("— a mark added after the same letters is the line growing (novel-box: 」 drawn after the round settled)")
    lines = ShownLines<Int>()
    note("「うん、ちょっと用事があって……", letters: row([0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 550]))
    note("「うん、ちょっと用事があって……」", letters: row([0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 550])) // grew
    note("「うん、ちょっと用事があって……」そう言って彼女は", breaks: [17], letters: row(Array(stride(from: 0, to: 1000, by: 50)))) // new line

    let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/shown-lines.txt")
    if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
        try output.write(to: golden, atomically: true, encoding: .utf8)
    }
    let expected = try String(contentsOf: golden, encoding: .utf8)
    let (got, want) = (output.split(separator: "\n"), expected.split(separator: "\n"))
    for (i, (a, b)) in zip(got, want).enumerated() where a != b {
        Issue.record("line \(i + 1):\n  got      \(a)\n  expected \(b)")
    }
    #expect(got.count == want.count)
}
