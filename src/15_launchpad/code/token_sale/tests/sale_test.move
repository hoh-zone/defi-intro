#[test_only]
module token_sale::sale_test;
use token_sale::sale;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario;

const ADMIN: address = @0xAD;
const USER1: address = @0xB0;
const USER2: address = @0xC0;

fun mint_sui(amount: u64, ctx: &mut sui::tx_context::TxContext): coin::Coin<SUI> {
    let mut treasury = coin::create_treasury_cap_for_testing<SUI>(ctx);
    let c = coin::mint(&mut treasury, amount, ctx);
    sui::transfer::public_transfer(treasury, ctx.sender());
    c
}

#[test]
fun full_lifecycle() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();

    // Manually create the sale using test-only helper
    let treasury = coin::create_treasury_cap_for_testing<sale::SALE>(ctx);
    sale::create_for_testing(treasury, 1, 1, 1_000_000_000_000, 10_000_000_000_000, ctx);

    // Objects are available after next_tx
    scenario.next_tx(ADMIN);

    // Take the shared SaleRound and the AdminCap
    let mut sale = test_scenario::take_shared<sale::SaleRound>(&scenario);
    assert!(sale::state(&sale) == 0); // CREATED

    // Admin adds whitelist
    let cap = test_scenario::take_from_sender<sale::AdminCap>(&mut scenario);
    sale::add_to_whitelist(&cap, &mut sale, USER1);
    assert!(sale::is_whitelisted(&sale, USER1));
    assert!(!sale::is_whitelisted(&sale, USER2));
    test_scenario::return_to_sender(&mut scenario, cap);
    test_scenario::return_shared(sale);

    // Start whitelist phase
    scenario.next_tx(ADMIN);
    let mut sale = test_scenario::take_shared<sale::SaleRound>(&scenario);
    let cap = test_scenario::take_from_sender<sale::AdminCap>(&mut scenario);
    sale::start_whitelist(&cap, &mut sale);
    assert!(sale::state(&sale) == 1); // WHITELIST
    test_scenario::return_to_sender(&mut scenario, cap);
    test_scenario::return_shared(sale);

    // User1 purchases (whitelisted) -- price=1 so payment=amount
    scenario.next_tx(USER1);
    let mut sale = test_scenario::take_shared<sale::SaleRound>(&scenario);
    let payment = mint_sui(1_000_000_000_000, scenario.ctx());
    sale::purchase(&mut sale, payment, scenario.ctx());
    assert!(sale::total_sold(&sale) == 1_000_000_000_000);
    assert!(sale::has_purchased(&sale, USER1));
    test_scenario::return_shared(sale);

    // Start public sale
    scenario.next_tx(ADMIN);
    let mut sale = test_scenario::take_shared<sale::SaleRound>(&scenario);
    let cap = test_scenario::take_from_sender<sale::AdminCap>(&mut scenario);
    sale::start_public_sale(&cap, &mut sale);
    assert!(sale::state(&sale) == 2); // PUBLIC
    test_scenario::return_to_sender(&mut scenario, cap);
    test_scenario::return_shared(sale);

    // User2 purchases (public)
    scenario.next_tx(USER2);
    let mut sale = test_scenario::take_shared<sale::SaleRound>(&scenario);
    let payment2 = mint_sui(500_000_000_000, scenario.ctx());
    sale::purchase(&mut sale, payment2, scenario.ctx());
    assert!(sale::total_sold(&sale) == 1_500_000_000_000);
    test_scenario::return_shared(sale);

    // End sale
    scenario.next_tx(ADMIN);
    let mut sale = test_scenario::take_shared<sale::SaleRound>(&scenario);
    let cap = test_scenario::take_from_sender<sale::AdminCap>(&mut scenario);
    sale::end_sale(&cap, &mut sale);
    assert!(sale::state(&sale) == 3); // ENDED
    test_scenario::return_to_sender(&mut scenario, cap);
    test_scenario::return_shared(sale);

    // Start distribution
    scenario.next_tx(ADMIN);
    let mut sale = test_scenario::take_shared<sale::SaleRound>(&scenario);
    let cap = test_scenario::take_from_sender<sale::AdminCap>(&mut scenario);
    sale::start_distribution(&cap, &mut sale);
    assert!(sale::state(&sale) == 4); // DISTRIBUTED
    test_scenario::return_to_sender(&mut scenario, cap);
    test_scenario::return_shared(sale);

    // User1 claims
    scenario.next_tx(USER1);
    let mut sale = test_scenario::take_shared<sale::SaleRound>(&scenario);
    let tokens1 = sale::claim(&mut sale, scenario.ctx());
    assert!(coin::value(&tokens1) == 1_000_000_000_000);
    sui::transfer::public_transfer(tokens1, test_scenario::sender(&mut scenario));
    test_scenario::return_shared(sale);

    // User2 claims
    scenario.next_tx(USER2);
    let mut sale = test_scenario::take_shared<sale::SaleRound>(&scenario);
    let tokens2 = sale::claim(&mut sale, scenario.ctx());
    assert!(coin::value(&tokens2) == 500_000_000_000);
    sui::transfer::public_transfer(tokens2, test_scenario::sender(&mut scenario));
    test_scenario::return_shared(sale);

    scenario.end();
}
