# 18.1 从教学原型到可维护代码

## 模块分离

教学代码通常是一个文件里写完所有逻辑。生产代码需要按职责分离：

```
sources/
├── config/
│   ├── risk_config.move      # 风险参数定义
│   └── admin.move            # 管理员操作
├── state/
│   ├── pool.move             # 池子状态
│   ├── position.move         # 仓位状态
│   └── reserve.move          # 储备状态
├── actions/
│   ├── deposit.move          # 存款逻辑
│   ├── borrow.move           # 借款逻辑
│   ├── repay.move            # 还款逻辑
│   └── liquidate.move        # 清算逻辑
├── math/
│   ├── interest.move         # 利率计算
│   ├── health_factor.move    # 健康因子
│   └── amm_math.move         # AMM 计算
├── events/
│   └── protocol_events.move  # 事件定义
├── errors/
│   └── error_codes.move      # 错误码
└── protocol.move             # 入口模块
```

## 标准化的权限模式

```move
module protocol::admin {
    use sui::object::{Self, UID};

    public struct AdminCap has key, store {
        id: UID,
        roles: u64,
    }

    const ROLE_PAUSE: u64 = 1;
    const ROLE_PARAMS: u64 = 2;
    const ROLE_ORACLE: u64 = 4;
    const ROLE_EMERGENCY: u64 = 8;

    public fun has_role(cap: &AdminCap, role: u64): bool {
        (cap.roles & role) == role
    }

    public fun require_role(cap: &AdminCap, role: u64) {
        assert!(has_role(cap, role), 0);
    }
}
```

通过位掩码实现角色分离：暂停、参数修改、预言机管理、紧急操作各自独立授权。

## 标准化的事件模式

```move
module protocol::events {
    public struct DepositEvent has copy, drop {
        pool_id: ID,
        user: address,
        amount: u64,
        shares_minted: u64,
        timestamp: u64,
    }

    public struct BorrowEvent has copy, drop {
        pool_id: ID,
        user: address,
        amount: u64,
        health_factor_after: u64,
        timestamp: u64,
    }

    public struct LiquidationEvent has copy, drop {
        pool_id: ID,
        borrower: address,
        liquidator: address,
        debt_repaid: u64,
        collateral_seized: u64,
        timestamp: u64,
    }
}
```

## 标准化的错误码

```move
module protocol::errors {
    const EInvalidAmount: u64 = 0;
    const EInsufficientLiquidity: u64 = 1;
    const EHealthFactorTooLow: u64 = 2;
    const EPoolPaused: u64 = 3;
    const EUnauthorized: u64 = 4;
    const EPriceStale: u64 = 5;
    const EPriceDeviation: u64 = 6;
    const EPositionNotFound: u64 = 7;
    const EDuplicatePosition: u64 = 8;
    const EExceedsLimit: u64 = 9;
}
```

## 推荐的重构顺序

1. 先分离错误码和事件（最安全、影响最小）
2. 分离数学模块（纯函数，无副作用）
3. 分离状态定义（struct 定义独立出来）
4. 分离操作逻辑（按业务功能拆分）
5. 最后调整入口模块（整合所有子模块）
