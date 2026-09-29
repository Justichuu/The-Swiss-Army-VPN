# Swiss Army VPN

就这一页。只能读一份的话，读这份。

## 这是什么

一个很小的 Windows 窗口，用来管 Windows 本来就会的 VPN。VPN 断了，它可以把其余上网一起切断。这个切断叫 kill switch（锁）。

这不是 NordVPN 公司。也不是一家新的 VPN 店。账号你自己带。

## 它会在电脑上做什么

- 加一个名叫 Swiss Army VPN 的 Windows VPN。
- 可以打开四条防火墙规则，挡住普通上网。
- 可以保存用户名和密码，由 Windows 保管。
- 可以换服务器。

不读你的文件。不记你去过的网站。不存你的 GitHub 令牌。

## 它不会做什么

不跑 WireGuard，也不跑 OpenVPN。

它不能单靠自己让坏网络变安全。只有锁开着、而且隧道是这个程序在看的那条，才有用。

## 怎么开始

1. 从 GitHub 最新 Release 下载 zip。不要用绿色的 Code。
2. 打开文件夹。文件不要拆开。
3. 运行 `Install Swiss Army VPN.exe`。Windows 会要管理员许可。
4. 打开程序。选 SET UP SIGN-IN。填你自己的 VPN 账号。
5. 要锁就按 CONNECT + ARM。不要锁就按 CONNECT。

## 怎么停

按 DISCONNECT + UNLOCK。

窗口打不开、网也死了：开始菜单里的 Emergency Unlock。

## 卡住了

锁可以让整台电脑上不了网。这就是设计。先解锁。

不要发原始日志。要分享状态，先跑清洗工具。

## 隐私

密码留在 Windows。不要脸、不要声音、不要限时测验。

安全问题走 GitHub security advisories。不要把密码写进 issue。

## 谁做的

Justichuu。非正式。GPL-3.0-only。代码可以读。
