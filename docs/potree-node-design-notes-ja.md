# PotreeConverter のノード設計に関する調査メモ

> この文書は Potree 公式ドキュメントではありません。PotreeConverter の実装を読んだ上での個人的な調査メモです。

## 背景

PotreeConverter 2.0 は、LAS/LAZ 点群を Potree v2 形式の以下3ファイルへ変換する。

- `metadata.json`
- `hierarchy.bin`
- `octree.bin`

旧形式のようにノードごとに大量のファイルを作るのではなく、点データ本体を `octree.bin` に集約し、階層情報を `hierarchy.bin` に持つ。この設計により、ファイル数の爆発を避け、大規模点群でも高速に変換・配信しやすくしている。

一方で、Potree viewer 側では概ね node 単位が runtime cost に直結する。

```text
node = hierarchy entry
node = fetch range
node = decode unit
node = GPU buffer unit
node = draw call candidate
```

そのため、1KB 未満のような極端に小さい node が多数生成されると、ネットワーク RTT、fetch scheduling、decode、draw call の固定費が支配的になり、ビューア体験が悪化しやすい。

## 現状実装の大枠

本家 PotreeConverter の処理は、大きく `chunking` と `indexing/sampling` に分かれる。

```text
1. 入力 LAS/LAZ の bounding box、点数、属性を読む

2. chunking
   - 入力点を走査して coarse grid の点数を数える
   - 点数分布から大きすぎない chunk 境界を決める
   - 入力を再度読んで chunk ファイルへ分配する

3. indexing
   - chunk ファイルを読み込む
   - chunk 内で octree 構造を作る
   - leaf 側に点を配置する

4. sampling
   - leaf から bottom-up に処理する
   - 子ノード群の点から親ノード用の代表点を選ぶ
   - 選ばれなかった点を子ノード側に残す
   - 完了した node を octree.bin へ書き出す

5. hierarchy.bin / metadata.json を作る
```

重要なのは、Potree の node は「その空間範囲に含まれる全点」ではなく、「その LOD 階層で追加表示する点の差分」を持つという点である。

## 1万点という値の意味

本家実装の `indexer` には、概ね以下のような上限がある。

```cpp
constexpr int maxPointsPerChunk = 10'000;
```

これは「各 node を1万点に揃える」という目標値ではない。実際には、主に以下の判断に使われる。

```text
if node.points > 10,000:
    さらに空間分割する
else if node.points > 0:
    node として採用する
```

つまり、1万点は「分割するかどうかの上限閾値」であって、「runtime に都合のよい目標粒度」ではない。

そのため、1点から1万点までの node が普通に許容される。ここに `minPointsPerNode` や `minBytesPerNode` のような下限はない。

## 細切れ node が発生する理由

細切れ node が発生する直接的な理由は、主に以下である。

- 空間 octree は bin packing ではない
- 分割基準は点数上限であり、点数下限がない
- 密な領域に合わせて分割すると、同じ親配下の疎な領域も細かい空間セルになる
- sampling 後、子 node に少数の rejected 点だけが残ることがある
- rejected が1点でも残れば node として書き出される

例:

```text
親セル: 50,020 点
  子0: 49,990 点
  子1: 10 点
  子2: 20 点
```

親セルは 10,000 点を超えるため分割される。子0 はさらに分割されるが、子1 や子2 は `0 < points <= 10,000` なので、そのまま独立 node になり得る。

さらに bottom-up sampling では、子 node の点から親 node 用の代表点を吸い上げる。

```text
child points を走査
accepted -> parent
rejected -> child
if rejected > 0:
    child を node として書き出す
```

ここで `rejected` が数点しかなくても、現状では独立 node として書き出される。これが 1KB 未満 node の直接的な発生源になる。

## sparse inner node が発生する理由

leaf だけでなく、inner node がスカスカになることもある。

```text
親 node: 代表点を持つ
  子 node: ほとんど点を持たない
    孫 node: 詳細点を持つ
```

これは、親 node が子 node の代表点をさらに吸い上げることで起きる。

例:

```text
子 node が孫から 50 点の代表点を得る
親 node の sampling で、その 50 点のうち 48 点が親に採用される
子 node には 2 点だけ残る
孫 node には詳細点が残っている
```

これは LOD 構造としては矛盾しない。疎な領域では、粗い表現は親 node に吸収済みで、中間 LOD として追加する点がほとんどない一方、さらに近づいたときの詳細点は子孫に残る、という状態である。

ただし runtime 上は、点数の少ない inner node が fetch/decode/draw の対象になると無駄が大きい。

## sampling の性質

デフォルトの sampling method は `poisson` である。

選択肢は主に以下。

```text
-m poisson
-m poisson_average
-m random
```

`poisson` は、点数目標ではなく spacing に基づいて代表点を選ぶ。

```text
spacing = baseSpacing / 2^node.level
```

そして、代表点同士が `spacing` 未満に近づきすぎないように accepted point を選ぶ。単純な voxel sampling ではなく、Poisson-disk sampling に近い。

したがって、親 node に吸い上げる点数には明示的な目標値がない。点数は以下の条件から結果的に決まる。

- node の空間サイズ
- node level
- base spacing
- 点密度
- 点群が面状、線状、体積状のどれに近いか
- 候補点の分布
- Poisson 判定の近似

LOD として重要なのは「各 node を1万点に揃えること」ではなく、「親 node 単体で見たときに、その bbox 内の点群分布を空間的に偏りなく代表していること」である。

## Brotli 前提の node size 感

属性を `position + rgb` のみにした場合、非圧縮では以下になる。

```text
position: int32 x 3 = 12 bytes/point
rgb:      uint16 x 3 = 6 bytes/point
合計:                  18 bytes/point
```

1万点なら:

```text
10,000 points x 18 bytes = 180,000 bytes
約 176 KiB
```

Brotli 圧縮を前提にすると、実データの性質に強く依存するが、1万点 node は概ね以下の範囲が目安になる。

```text
かなり良い:  30KB-60KB
普通:        60KB-120KB
悪い:       120KB-200KB+
```

実務上は、1万点 node は Brotli 後で 64KB から 128KB 程度を期待値に置ける。これは現代のネットワーク環境では小さすぎず大きすぎない fetch 単位と考えられる。

## 現状設計の評価

本家 PotreeConverter の基本設計は、大規模点群変換として根本的に破綻しているわけではない。

妥当な点:

- out-of-core 前提の chunking + indexing
- 空間 octree による LOD
- bottom-up sampling
- 親 node に粗い LOD、子孫 node に詳細点
- 3ファイル形式への集約
- viewer が node 単位で streaming できる

一方で、最適化の目的関数は converter 側の速度と単純性に寄っている。

不足している点:

- node size の下限がない
- tiny remainder を抑制しない
- sparse inner payload を特別扱いしない
- node size 分布の評価がない
- viewer の fetch/draw cost を直接は最適化していない

したがって、現状の問題は「ノード設計が根本的に間違っている」というより、「業務用途・国土級配信を意識すると node 粒度制御が不足している」という整理が妥当である。

## 改善案1: サンプリング中に tiny remainder を親へ戻す

最初に入れるべき小改善として、sampling 中の局所ルールが妥当である。

現状:

```text
child points を走査
accepted -> parent
rejected -> child
if rejected > 0:
    child を node として書き出す
```

改善案:

```text
child points を走査
accepted -> parent
rejected -> child

if rejectedBytes < minNodeBytes:
    rejected も parent に入れる
    child は node として書き出さない
else:
    child を node として書き出す
```

この方式は追加コストが小さい。

- すでに child points は読んでいる
- accepted/rejected の振り分けも既存処理で行っている
- 追加で見るのは `numRejected` や `rejectedBytes`
- 全点をメモリに上げる必要がない
- hierarchy 全体の再最適化も不要

設計パラメータ例:

```text
targetNodePoints: 10,000
minNodePoints:    512-1,000
minNodeBytes:     16KB-32KB
maxParentPointsAfterAbsorb: 20,000-30,000
```

注意点:

- 親 node が大きくなりすぎない上限が必要
- 吸収した点は子側に残さない
- leaf と inner node で扱いを分ける
- inner node は構造上必要な場合があるため、payload だけ親へ吸収し、node 自体は残す選択肢がある

## 改善案2: 書き出し前の node stats 評価と collapse plan

もう一つの妥当な改善は、`hierarchy.bin` / `octree.bin` に本書き出しする前に、node stats を評価することである。

評価対象は点そのものではなく、node metadata にする。

収集する情報:

```text
level
numPoints
byteSize
bbox
childMask
parent / children
depth
spacing
density
```

評価指標:

```text
tiny node ratio:
  byteSize < 16KB の node 割合

point count distribution:
  p10 / p50 / p90 / p99 の numPoints

level balance:
  level ごとの node 数、点数、平均 byteSize

draw pressure estimate:
  ある LOD 閾値で可視化される想定 node 数

parent-child imbalance:
  親に対して極端に小さい child が多い場所
```

処理イメージ:

```text
1. provisional octree / sampling result を作る
2. node stats を集める
3. tiny node や sparse payload を検出する
4. collapse plan を作る
5. 対象 node だけ点バッファを触って plan を適用する
6. octree.bin / hierarchy.bin を書き出す
```

ここで重要なのは、全点を保持しないこと。保持するのは metadata と、collapse 対象になった小さな node の点バッファ程度に留める。

避けるべき処理:

- 全ノードを見て完全な最適 merge plan を作る
- 複数階層をまたいだ重い再配置
- octree 全体の複数回再書き込み
- 点をグローバルに並べ替える処理

目標は「最適な octree」ではなく、以下のような制約充足にするのが現実的である。

```text
minNodeBytes 未満の node を一定割合以下にする
平均 draw call 推定値を一定以下にする
level ごとの点数分布を極端に崩さない
```

## fetch coalescing について

viewer 側で近接 byte range をまとめて fetch する request coalescing は、ネットワーク RTT 対策として有効である。

ただし Potree v2 互換を保つ場合、node と draw call の結合は残る。そのため、fetch coalescing だけでは draw call 増加問題は解決しない。

converter 側で吸収すべき本質対策は、やはり「小さすぎる logical node を作らない」ことである。

## 入力点群の前処理の重要性

外れ値ノイズや孤立点が広範囲に散っていると、root bbox が大きくなる。

Potree の spacing は概ね root size に引っ張られる。

```text
baseSpacing = rootSize / 128
spacing(level) = baseSpacing / 2^level
```

そのため、外れ値で bbox が大きくなると以下が起きる。

- 上位 LOD の spacing が大きくなる
- 撮影対象の粗い LOD が薄くなる
- 必要な詳細 spacing に到達するまで深い level が必要になる
- hierarchy が深くなる
- sparse/tiny node が増えやすい
- ノイズ点が粗い LOD に混ざりやすい

十分に深掘りできれば最終的な詳細 LOD は回復するが、探索コスト、fetch、draw call、上位 LOD 品質は悪化する。

したがって、入力点群の前処理は非常に重要である。

推奨フロー:

```text
1. 対象範囲で crop / clip
2. 外れ値・孤立点の除去
3. 明らかなノイズの手動除去
4. 必要に応じて classification filter
5. 目標品質に合わせた間引き
6. Potree 用変換
```

converter 側の tiny node 抑制は、悪い入力でも破綻しにくくするための改善である。最も効果が大きいのは、入力点群を適切な空間範囲、密度、ノイズ状態に整えることである。

## まとめ

本家 PotreeConverter のノード設計は、大規模点群を高速に変換するという目的に対して概ね妥当である。

一方で、業務用途や国土級配信を考えると、node が runtime unit として viewer に露出しているため、1KB 未満のような tiny node は UX 上の問題になりやすい。

現実的な改善方針は以下。

```text
1. sampling 中に tiny remainder を親へ戻す局所ルールを入れる
2. minNodePoints / minNodeBytes を導入する
3. inner node は構造と payload を分けて扱う
4. 書き出し前に node stats を評価する
5. 対象限定の collapse plan を適用する
6. 入力点群の crop / noise removal / decimation を重視する
```

互換性を保つなら、node と fetch unit を分離するようなフォーマット変更は避けるべきである。Potree v2 形式のまま改善するなら、converter 側で「小さすぎる logical node を作らない」方向に寄せるのが最も筋が良い。

## PotreeConverter 改善検討の進め方

ここから先は、`potree-node-stats` コマンドが使える前提で、本家 PotreeConverter の小ノード問題をどう検討するかを実務向けに整理する。

この節の目的は次の 2 点である。

```text
1. 前処理で改善できる部分と、converter 側で改善すべき部分を切り分ける
2. converter 改造の良し悪しを node stats で定量評価する
```

前提として、本メモの前半で述べたとおり、小ノード問題の原因は単一ではない。

```text
- 入力点群の bbox が大きすぎる
- 外れ値や孤立点が spacing / depth を悪化させる
- 複数スキャン重畳で局所密度が高すぎる
- sampling 後の tiny remainder がそのまま node になる
- sparse inner payload を抑制する仕組みがない
```

したがって、改善検討では「前処理」と「converter 実装」の寄与を分離して見る必要がある。

## まず見るべき結論

現時点での暫定結論は以下である。

```text
1. 前処理は重要である
2. ただし前処理だけでは tiny node / sparse inner node は残り得る
3. よって PotreeConverter 側にも改善余地がある
```

この結論は、以下のようなケースで特に強く当てはまる。

```text
- 複数スキャンを単純結合した LiDAR 点群
- 外れ値で root bbox が不必要に広がっている点群
- 面状構造と細線構造が混在する設備系点群
- 高密度だが局所的に疎な領域も多い indoor / plant 系点群
```

## 評価に使う指標

`potree-node-stats` を使うなら、まず summary と 3 つの表から次の指標を読む。

### summary 系

```text
total nodes
leaf nodes
inner nodes
zero-point nodes
tiny <= 1KB
small <= 16KB
payload p50 / p90 / p99
points p50 / p90 / p99
```

### level 分布系

```text
最深 1-2 level に node が集中していないか
深い level で zero / <=1KB / <=100 point が爆発していないか
level ごとの avg points が末端で極端に小さくなっていないか
```

### sparse inner 系

```text
sparse ratio がどの level で高いか
zero payload inner node が最深 level 近辺に偏っていないか
中間 level に無駄な inner node が残っていないか
```

実務上は、総点数よりも node shape を重視したほうがよい。

```text
悪い例:
  点数は減ったが、tiny node ratio が増えた

良い例:
  総点数は少し増えても、deep level 集中と tiny node ratio が減った
```

## 良し悪しの目安

データ依存ではあるが、初期の目安としては以下のように見るとよい。

```text
tiny <= 1KB ratio:
  10% 未満    良い
  10-30%      許容
  30-50%      要観察
  50% 超      改善余地が大きい

zero-point ratio:
  数% 未満    許容
  10% 近い    要観察
  10% 超      改善余地が大きい

sparse inner ratio:
  深い level だけ多少高い     許容
  中間 level から高い         要観察
  広範囲に高い                converter 側改善候補
```

これは絶対基準ではないが、比較実験の判定には十分使える。

## 比較実験の切り方

改善検討では、条件を一度に複数変えすぎないことが重要である。

最初の比較軸は次の 2 本に分ける。

### 1. 前処理の寄与を見る比較

同じ元データに対して以下を比較する。

```text
A. raw
B. SOR only
C. voxel sampling only
D. SOR + voxel sampling
```

この比較で分かること:

```text
- bbox / depth 改善に効いているのはどちらか
- tiny node 抑制に効いているのはどちらか
- zero-point node 抑制に効いているのはどちらか
- sampling 幅を大きくする前にノイズ除去が必要か
```

### 2. converter の寄与を見る比較

前処理条件を固定した上で、converter 実装だけを変える。

```text
A. baseline
B. minNodeBytes のみ導入
C. minNodePoints のみ導入
D. tiny remainder absorb 導入
E. absorb + inner payload special handling
```

この順序で見れば、「前処理で良くなった」のか「converter 改造で良くなった」のかを混同しにくい。

## 最初に試すべき converter 改善

最初の一手として最も筋が良いのは、前半で述べた tiny remainder 吸収である。

### 改善案A: tiny remainder を親へ戻す

狙いは単純である。

```text
rejected が少なすぎる子 node は独立 payload にしない
```

導入パラメータ例:

```text
minNodeBytes: 16KB or 32KB
minNodePoints: 512 or 1000
maxParentPointsAfterAbsorb: 20000-30000
```

期待する改善:

```text
- tiny <= 1KB ratio が下がる
- small <= 16KB ratio が下がる
- deepest level の node 数が減る
- zero-point ではないが極小の leaf が減る
```

副作用として見ておくべき点:

```text
- 親 payload が大きくなりすぎないか
- LOD の見た目が粗くなりすぎないか
- parent-child imbalance が別の形で悪化しないか
```

### 改善案B: inner node の payload と構造を分けて扱う

inner node は階層構造として必要でも、payload は tiny であることがある。

したがって、以下の扱いを検討する価値がある。

```text
- child mask と hierarchy 上の存在は維持する
- ただし tiny payload は親へ吸収する
- inner node としての論理構造は壊さない
```

これは leaf の単純吸収より難しいが、sparse inner ratio の改善には効きやすい。

### 改善案C: 書き出し前に node stats を見て collapse plan を作る

これは 2 段階目の改善として妥当である。

```text
1. provisional result を作る
2. node stats を集める
3. collapse 対象を限定抽出する
4. 対象だけ再配置する
```

この方式はより柔軟だが、実装コストは上がる。最初からここに行くより、まずは sampling 中の局所ルールを先に入れたほうがよい。

## 実験手順

実験時は `potree-node-stats` の出力をそのまま比較ログに残す。

コマンド例:

```powershell
potree-node-stats .\path\to\dataset\
potree-node-stats .\path\to\dataset\ --format markdown
potree-node-stats .\path\to\dataset\ --levels 6.. --leaf-only
potree-node-stats .\path\to\dataset\ --levels 5.. --inner-only --include-zero
```

見る順序の例:

```text
1. summary で total / zero / tiny / payload p50 を見る
2. Point count distribution で deepest level 集中を見る
3. Payload size distribution で <=1KB, <=4KB の偏りを見る
4. Sparse inner table で中間 level の無駄を確認する
5. leaf-only / inner-only で問題の所在を切り分ける
```

ログの残し方としては、比較表を 1 つ作るのがよい。

```text
dataset
preprocess
converter variant
total nodes
zero-point ratio
tiny <= 1KB ratio
small <= 16KB ratio
payload p50
payload p90
max level
notes
```

## 改善採用の判断基準

converter 改善を採用するなら、少なくとも次を満たしたい。

```text
1. tiny <= 1KB ratio が明確に下がる
2. zero-point ratio が悪化しない
3. payload p90 / p99 が過大化しない
4. deepest level 集中が緩和する
5. viewer 上の見た目が破綻しない
6. 変換時間やメモリが極端に悪化しない
```

ここで重要なのは、tiny node を消すために巨大 node を作りすぎないことだ。評価の目的は「全部を大きい node に寄せること」ではなく、「runtime に不利な極小 node を抑えつつ、LOD 品質を保つこと」である。

## 実施結果メモ 2026-05-04

`testing/test-data/mp_e57_Mechanical-room.laz` を使って、`poisson` sampling に tiny remainder 吸収を入れた版を評価した。

実装ルール:

```text
- rejectedBytes < 16KB の child remainder は親へ吸収する
- ただし吸収後の parent points が 30,000 を超える場合は吸収しない
```

### converter 側の結果

baseline と改善版の `potree-node-stats` 比較では、以下の改善を確認した。

```text
total nodes:            54,843 -> 23,095
leaf nodes:             45,479 -> 16,829
leaf tiny <= 1KB:       13,500 -> 256
leaf small <= 16KB:     32,364 -> 722
leaf zero-point:         8,737 -> 0
inner zero payload:         89 -> 20
inner small <= 16KB:        89 -> 25
conversion duration:     62.6s -> 56.9s
```

読み方として重要なのは、payload 総量は大きく変えずに、viewer に不利な極小 leaf を大きく減らせた点である。

### viewer 実測の結果

同一視点・同一点予算で viewer 実測も行い、以下の改善を確認した。

```text
visible nodes:      3,334 -> 1,630
draw calls PC:      3,334 -> 1,630
CPU work avg:      16.50 -> 7.14 ms
update avg:         4.80 -> 2.23 ms
render avg:        11.60 -> 4.86 ms
GPU time avg:      10.07 -> 7.75 ms
fetch events:       3,642 -> 1,664
octree read avg:    6.83 -> 1.48 ms
hierarchy load avg:13.33 -> 2.14 ms
```

`Fetched bytes` はほぼ同じだったため、効いているのは総転送量削減ではなく、細切れ node に伴う fetch / decode / draw call の固定費削減と考えてよい。

### 今回の結論

今回の tiny remainder 吸収は、`potree-node-stats` と viewer 実測の両方で改善が確認できたため、採用に値する小改善と判断できる。

一方で、残る sparse inner は主に hierarchy を成立させるための structural placeholder であり、tiny leaf と同じ優先度ではない。viewer 側で draw call を大きく増やす性質でもないため、現時点では無理に collapse しない判断が妥当である。

## 推奨する進め方

今の段階なら、改善検討は次の順序が現実的である。

```text
1. raw / SOR / voxel / SOR+voxel を比較する
2. voxel 幅を 1mm, 2mm, 3mm, 5mm などで振る
3. 前処理条件を固定して baseline converter を測る
4. minNodeBytes を入れた converter を測る
5. tiny remainder absorb を入れた converter を測る
6. 必要なら sparse inner 向けの追加処理を検討する
```

最初から複雑な collapse plan に進まず、`minNodeBytes` 系の局所ルールでどこまで改善するかを見るのがよい。

## このメモの位置づけ

本メモは、PotreeConverter を全面的に作り直す提案ではない。

位置づけは以下である。

```text
- Potree v2 互換を保つ
- viewer 側変更を前提にしない
- converter 側の小改善から始める
- `potree-node-stats` で改善効果を定量比較する
```

したがって、今後の作業単位としては次のような粒度が適切である。

```text
task 1: 比較実験マトリクスを埋める
task 2: minNodeBytes 仮実装を入れる
task 3: raw / 改善版の node stats を比較する
task 4: viewer 上の見た目と応答感を確認する
task 5: 必要なら inner payload 改善へ進む
```
