/// 教学用：算法稳定币**供给调节**的最小状态机（非生产级）。
///
/// 历史上纯算法币（无足额抵押）在压力下多次失败。本模块只演示：
/// - 协议如何记录「名义供给」与部分准备金；
/// - 治理或规则如何触发 **扩张 / 收缩**。
/// **不包含** AMM、预言机或可信的锚定机制——那些才是真实系统的难点。
module algorithmic_stablecoin_sketch::algo;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;

    /// 模块 `algo` 的一次性见证（OTW）。
    public struct ALGO has drop {}

    #[error]
    const EInvariant: vector<u8> = b"Invariant";

    public struct AlgoEngine has key {
        id: UID,
        nominal_supply: u64,
        reserve: u64,
        peg_numerator: u64,
        peg_denominator: u64,
    }

    public struct GovernanceCap has key, store {
        id: UID,
    }

    fun init(_witness: ALGO, ctx: &mut TxContext) {
        transfer::share_object(AlgoEngine {
            id: object::new(ctx),
            nominal_supply: 0,
            reserve: 0,
            peg_numerator: 1,
            peg_denominator: 1,
        });
        transfer::transfer(
            GovernanceCap { id: object::new(ctx) },
            ctx.sender(),
        );
    }

    public fun contraction_burn(
        engine: &mut AlgoEngine,
        burn_supply: u64,
        release_reserve: u64,
    ) {
        assert!(engine.nominal_supply >= burn_supply, EInvariant);
        assert!(engine.reserve >= release_reserve, EInvariant);
        engine.nominal_supply = engine.nominal_supply - burn_supply;
        engine.reserve = engine.reserve - release_reserve;
    }

    public fun governance_expand(
        _: &GovernanceCap,
        engine: &mut AlgoEngine,
        add_supply: u64,
        add_reserve: u64,
    ) {
        engine.nominal_supply = engine.nominal_supply + add_supply;
        engine.reserve = engine.reserve + add_reserve;
    }

    public fun set_peg(_: &GovernanceCap, engine: &mut AlgoEngine, num: u64, den: u64) {
        assert!(den > 0, EInvariant);
        engine.peg_numerator = num;
        engine.peg_denominator = den;
    }
