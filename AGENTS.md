# リポジトリ指示
- コミットメッセージは必ず日本語で書くこと。

## コマンド類
- ビルドコマンド：
	- cmake -S . -B build -A x64
	- cmake --build build --config Release --parallel
- PotreeConverter本体
	- build\Release\PotreeConverter.exe
- potree-node-stats 【PotreeConverter変換後のディレクトリ】：変換後のノード配置情報を確認するコマンド

## ドキュメント
必要であればルートディレクトリの`docs/`配下を確認してください。