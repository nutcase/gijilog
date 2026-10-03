# セキュリティ / Security

ギジログは会議の録音・文字起こし・OpenAI の API キーを扱います。脆弱性を見つけたら、公開の Issue には書かず、GitHub の [Report a vulnerability](https://github.com/nutcase/gijilog/security/advisories/new)（Security タブ）から非公開で知らせてください。

対象は `main` ブランチの最新版です。特に次のような問題の報告を歓迎します。

- API キーが Keychain 以外（会議のファイル、ログ、エラー表示など）に残る
- 録音・文字起こし・議事録が、意図しない場所や相手に送られる、または保存される
- 会議の内容（文字起こし）に含まれる指示で、議事録の生成が乗っ取られる

Gijilog handles meeting recordings, transcripts, and an OpenAI API key. Please report vulnerabilities privately through GitHub's [Report a vulnerability](https://github.com/nutcase/gijilog/security/advisories/new) form instead of opening a public issue. Only the latest `main` is supported.
