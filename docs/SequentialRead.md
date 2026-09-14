# 全エントリを 1 回で読む(フォーク独自の変更)

このフォーク(qoo-oji/Unrar.swift)が `Archive.forEachEntry(_:)` を加えた記録です(2026-09-14)。
メモリ上の書庫を読む変更は [MemoryArchive.md](MemoryArchive.md) にあります。upstream へ還元する予定はありません。

## 目的

`Archive.extract(_:)` は呼ぶたびに書庫を開き直し、見出しを先頭から辿って目的のエントリを探します。
**ソリッドの RAR では、読み飛ばすエントリも伸長しないと次へ進めない**ので、全エントリを 1 つずつ取り出すと
書庫の大きさの 2 乗に比例する時間がかかります。qooViewer(この fork の利用者)で書庫を展開したとき、
180MB・60 ファイルのソリッド RAR が 62 秒かかりました(同じ中身の非ソリッドは 1.4 秒)。

`forEachEntry` は書庫を 1 回だけ開いて見出しの順に進むので、伸長も 1 回で済みます(同じ書庫で 2.2 秒)。

## API

```swift
try archive.forEachEntry { entry in
    guard wanted(entry) else { return nil }        // nil: 読み飛ばす(RAR_SKIP)
    return { chunk in try handle.write(contentsOf: chunk) }  // 閉包: 中身をチャンクで受け取る
}
```

- エントリごとに `body` を呼ぶ。nil を返せば `RAR_SKIP`、閉包を返せば `RAR_TEST` で処理し、`UCM_PROCESSDATA` の
  コールバックでチャンクを渡す。`RAR_TEST` なので CRC は検証され、食い違えばチャンクを渡し終えたあとで
  `UnrarError.badData` を投げる(`extract(_:)` と同じ)。
- `body` かチャンクの閉包が投げたら、その場で止めて同じエラーを投げ直す(コールバックは -1 を返して unrar に
  エントリを捨てさせ、`RARProcessFile` の失敗より閉包のエラーを優先する)。
- ディレクトリのエントリも `body` に渡る(読み飛ばすかは呼び出し側が決める)。同じ名前のエントリが 2 つあれば 2 回呼ばれる。
- `Archive(data:)` の書庫でも同じように使える(`withOpenArchive` の中で完結するので、バッファは借りるだけ)。

## 追加・変更したファイル

| ファイル | 内容 |
|---|---|
| `Sources/Unrar/ArchiveSequentialRead.swift`(新規) | `forEachEntry(_:)`、チャンクの閉包と最初のエラーを持つ `ChunkContext`、C のコールバック |
| `Sources/Unrar/Archive.swift` | `withOpenArchive` を `private` から internal に(別ファイルの拡張から使うため) |
| `Tests/UnrarTests/SequentialReadTests.swift`(新規) | `extract(_:)` との一致(ファイル・メモリ、暗号化はパスワード付き)、読み飛ばし、閉包・`body` からのエラー、CRC エラー、パスワード無し |
| `Tests/UnrarTests/fixture/solid.rar`(新規) | `rar a -ma5 -s -m3` で作ったソリッド書庫(合成したテキスト 4 ファイル) |

既存の公開 API は変えていません。
