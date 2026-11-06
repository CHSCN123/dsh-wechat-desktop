# 发布到 npm（维护者用）

> 目标：让别人在 DSH 里一行装好 —— `dsh plugin --profile web add dsh-wx-desktop`

## 一次性准备

1. 有 npm 账号（https://www.npmjs.com/signup）。账号名字随便，包名是 `dsh-wx-desktop`（查过了，现在没人占用）。
2. 本地登录（会弹浏览器，你自己操作，别把密码给我）：

```powershell
cd E:\DSH\dsh-wx-desktop
npm login
```

3. 确认登录身份：

```powershell
npm whoami
```

## 发布

```powershell
cd E:\DSH\dsh-wx-desktop
npm pack --dry-run     # 先看一眼要发出去的文件（约 83 个，230 KB）
npm publish
```

- 如果让你输一次性验证码：`npm publish --otp=123456`（6 位动态码）。
- 想先发个测试版：`npm publish --tag beta`，别人要用 `dsh plugin --profile web add dsh-wx-desktop@beta`。

## 发布后验证

```powershell
npm view dsh-wx-desktop version          # 应显示 0.3.1
dsh plugin --profile web add dsh-wx-desktop   # 在任意机器上试装
```

## 以后更新

1. 改 `package.json` 的 `version`（语义化版本：修 bug +0.0.1，加功能 +0.1.0）；
2. `CHANGELOG.md` 加一节；
3. `git commit` + `git push`；
4. `npm publish`。

## 不要发出去的东西（已经在 .gitignore / files 里排除）

- `scripts/local-env.json`（本机真实 db 路径、小号 wxid、对方昵称）
- `scripts/bak-depersonalize/`、`*.bak-*`
- 任何 token / api key / key.json

发布前自查一遍：

```powershell
git grep -n -E "wxid_[a-z0-9]{8,}|LeStoreDownload|Users\\\\LX|sk-|api[_-]?key"
```
