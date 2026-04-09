# 附录 C Sui CLI 与开发环境

## 安装

```bash
# 安装 Sui CLI
cargo install --locked --git https://github.com/MystenLabs/sui.git --branch mainnet sui

# 验证安装
sui --version
```

## 常用命令

### 项目管理

```bash
# 创建新项目
sui move new my_project

# 构建项目
sui move build

# 运行测试
sui move test

# 运行测试（带详细输出）
sui move test -v

# 运行特定测试
sui move test test_deposit
```

### 部署与升级

```bash
# 发布到测试网
sui client publish --gas-budget 100000000

# 发布到主网
sui client publish --gas-budget 100000000 --network mainnet

# 升级已发布的包
sui client upgrade --gas-budget 100000000 --upgrade-capability <CAP_ID>
```

### 对象查询

```bash
# 查看对象详情
sui client object <OBJECT_ID>

# 查看地址拥有的对象
sui client objects <ADDRESS>

# 查看对象的所有者
sui client object <OBJECT_ID> --owner
```

### 交易

```bash
# 查看交易详情
sui client tx-block <TX_DIGEST>

# 查看交易的 effects
sui client tx-block <TX_DIGEST> --effects

# 查看 Gas 使用
sui client gas <ADDRESS>
```

### 环境管理

```bash
# 切换网络
sui client switch --env testnet
sui client switch --env mainnet

# 查看当前环境
sui client active-env

# 查看活跃地址
sui client active-address
```

## Move.toml 配置

```toml
[package]
name = "my_defi_protocol"
edition = "2024.beta"

[dependencies]
Sui = { git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "mainnet" }

[addresses]
my_defi_protocol = "0x0"
```

## 调试技巧

1. **使用 `sui::debug` 模块**打印调试信息
2. **使用 `#[test_only]`** 标记仅用于测试的函数
3. **使用 `test_scenario`** 模拟多用户交互
4. **检查事件的 `show-effects`** 查看交易效果

```bash
# 查看交易效果（含事件）
sui client tx-block <TX_DIGEST> --show-effects
```
