# メモリ上の書庫を読む(フォーク独自の変更)

このフォーク(qoo-oji/Unrar.swift)が upstream(mtgto/Unrar.swift `7216007` "Update unrar to v7.23")に
対して加えた変更の記録です。upstream へ還元する予定はなく、フォークとして育てる前提です。

## 目的

unrar の公開 API(`RAROpenArchiveEx`)は書庫を**ファイルパス**でしか受け取れません。そのため、別の書庫の
中に入っている RAR を読むには、いったん一時ファイルへ書き出す必要がありました。このフォークは、同梱の
unrar ソースに「メモリ上のバッファから読むモード」を足し、Swift 側に `Archive(data:)` を用意することで、
入れ子の RAR をディスクに出さずに読めるようにします。

## 追加・変更したファイル

| ファイル | 内容 |
|---|---|
| `Sources/Cunrar/file.hpp` / `file.cpp` | `File` にメモリモード(`MemData` / `MemSize` / `MemPos`)と `OpenMemory()` / `IsMemory()` を追加。`DirectRead` / `RawSeek` / `Tell` / `Close` / `IsOpened` / `operator=` / コンストラクタがメモリモードを扱う |
| `Sources/Cunrar/archive.hpp` / `archive.cpp` | `Archive::OpenMemory()`(QuickOpen のキャッシュを捨ててから `File::OpenMemory`) |
| `Sources/Cunrar/volume.cpp` | `MergeArchive` の冒頭で、メモリ上の書庫なら次巻を探さずに失敗させる(下記) |
| `Sources/Cunrar/dll.cpp` / `dll.hpp` / `include/unrar.h` | `RAROpenArchiveEx` の中身を `OpenArchiveCommon` に共通化し、`RAROpenArchiveMem(RAROpenArchiveDataEx*, const void*, size_t)` を追加 |
| `Sources/Unrar/Archive.swift` | `Archive.Source`(`.file(URL)` / `.memory(Data)`)、`init(data:password:)`、`init(source:password:)` を追加。開いて閉じる処理を `withOpenArchive` に共通化 |
| `Tests/UnrarTests/MemoryArchiveTests.swift`(新規) | ファイル版との一致、繰り返し読み、CRC エラー、ゴミデータ、途中で切れたデータ、分割ボリュームの扱い |
| `README.md` / `CHANGELOG.md` | 機能と使い方の追記 |

既存の公開 API は変更していません。`fileURL` は保持プロパティから計算プロパティになりましたが、ファイルから
開いた場合の値は同じです(メモリから開いた場合は `memory:` というプレースホルダ URL を返します。
判別には `source` を見てください)。

## unrar 側の設計

unrar の読み取りはすべて `File` クラスを通り、`Open` / `Close` / `Read` / `Seek` / `Tell` / `IsOpened` /
`FileLength` はもとから virtual ですが、DLL の `DataSet` は `Archive` を値で持つためサブクラスに差し替える
余地がありません。そこで `File` 自身にメモリモードを持たせました。実際の I/O は `DirectRead` と `RawSeek`
の 2 か所に集約されているので、分岐はそこと `Tell` / `Close` / `IsOpened` だけです。

- `OpenMemory(ptr, size)`: 既存のハンドルを閉じ、バッファと位置を設定する。バッファは**呼び出し側の所有**で、
  `Close()` まで有効でなければならない。
- `DirectRead`: `memcpy` して位置を進める。末尾では 0 を返す(エラーではない)。
- `RawSeek`: `SEEK_SET` / `SEEK_CUR` / `SEEK_END` を計算。`lseek` と同じく末尾より先への seek は許し、そこでの
  読み取りは 0 バイトになる。負の位置は失敗。
- `Close`: メモリモードを解除する(`SetHandle` など既存の経路が `Close` を呼ぶので、そこでも解除される)。

`MergeArchive`(次巻へ移る処理)は、メモリモードでは冒頭で失敗を返します。もとの実装は `Arc.Close()` して
から次巻をパスで開こうとし、DLL では開けないたびにコールバックへ `UCM_CHANGEVOLUME` を投げて再試行する
ループになっています。Unrar.swift のコールバックはこのメッセージに 0(=続行)を返すため、メモリ上の
分割書庫でこの経路に入ると**無限ループ**になります(実装中に実際に起きました)。

`RAROpenArchiveMem` は `RAROpenArchiveEx` と同じ初期化を通り、`Arc.Open(パス)` の代わりに
`Arc.OpenMemory` を呼ぶだけです。`ArcName` はメッセージ用の名前としてだけ使われます。

## Swift 側の設計

Unrar.swift は `entries()` / `extract()` / `comment()` のたびに書庫を開いて閉じる作りです。これを利用して、
メモリ版では各操作の本体を `data.withUnsafeBytes { ... }` の中で実行し、その中で `RAROpenArchiveMem` から
`RARCloseArchive` までを済ませます。ポインタが有効なのはクロージャの中だけですが、ハンドルもそこで
閉じるので問題なく、**書庫のバイト列をコピーせずに**済みます(SevenZip.swift 側の `Archive(data:)` が
1 回コピーするのと対照的です。あちらは `Archive` が開いたまま生き続けるため)。

## 制限

- 分割ボリューム(multi-volume)はメモリからは辿れません。最初の巻に収まっているエントリの一覧は取れますが、
  次巻にまたがるエントリの取り出しはエラーになります。
- `Archive` はスレッドセーフではありません(upstream と同じ)。

## 呼び出し側の関数から読む(`Source.reader`、2026-09-24)

メモリ入力と同じ仕組みで、読み取りを**呼び出し側の関数**へ回す入口も足しました。qooViewer がネットワーク
ボリューム上の書庫を、自前のブロックキャッシュ(読み込み層)を通して読むためのものです(unrar はヘッダーを
「7 バイト+残り」の 2 回の素の `read()` で読むので、SMB では 1 回ごとに往復を待ちます)。

- unrar 側: `File` に `CbRead` / `CbCtx` を足し、`OpenCallback(Read, Ctx, Size)` を追加。位置と大きさはメモリ
  モードの `MemPos` / `MemSize` を共用し、`DirectRead` だけが `memcpy` の代わりに関数を呼ぶ。`RawSeek` /
  `Tell` / `Close` / `IsOpened` / `IsMemory` はメモリモードと同じ扱い(`IsMemory` が真なので、分割ボリュームの
  次巻も同じく探さずに失敗する)。DLL に `RAROpenArchiveCallback(RAROpenArchiveDataEx*, Read, Ctx, Size)`。
  関数は `long long (*)(void *Ctx, long long Offset, void *Buf, size_t Size)` で、読めたバイト数(終わりで 0、
  失敗で -1)を返す。
- Swift 側: `Archive.Source.reader(PositionalReader)`。`PositionalReader(size:read:)` の `read` は短い読みを
  返してよい ―― unrar の `File::Read` は短い読みを「データの終わり」と受け取るので、Swift 側の橋渡しが
  バッファが埋まるまで(または 0 / -1 まで)繰り返して呼ぶ。
- 寿命: メモリ入力と同じく、各操作が開いて閉じる間だけ借りる(`withExtendedLifetime`)。

## テスト

```sh
swift test
```

`ReaderArchiveTests` は同じ fixture を `Source.reader` で読み、ファイル版と一致すること(1 回 7 バイトずつしか
返さない読み手でも)、`forEachEntry` の一致、読み取りの失敗で落ちずにエラーになること、ゴミデータ、分割
ボリュームの先頭巻を確認します。

`MemoryArchiveTests` は同梱 fixture(通常・マルチバイト名・RAR4 形式・BLAKE2・暗号化・ヘッダ暗号化)を
`Data` で読み込み、`entries()` と各エントリの `extract()`、`comment()` がファイル版と一致することを確認
します。加えて、同じ `Archive` を繰り返し読めること、CRC エラーがメモリ版でも報告されること、
ゴミデータや途中で切れたデータで落ちないこと、分割ボリュームの先頭巻をメモリから開いた場合の挙動を
確認します。

## upstream への追従

Unrar.swift は unrar の新版を年に数回取り込みます。パッチは `[qoo-oji fork]` のコメントで印を付けた
数十行(file.hpp / file.cpp / archive.hpp / archive.cpp / volume.cpp / dll.cpp / dll.hpp / include/unrar.h)
なので、`git merge upstream/main` で衝突したらこの印を頼りに当て直し、`swift test` を通してください
(呼び出し側の関数から読む入口も同じ印の中にあります)。
