#[test_only]
module object_basics::counter_test;
    use object_basics::counter;
    use sui::test_scenario;
    use sui::object;

    // ========== Test addresses ==========

    const ADMIN: address = @0xAD;
    const USER: address = @0xBA;

    // ========== Tests ==========

    #[test]
    /// Test that creating a counter produces valid objects
    fun create_counter() {
        let mut scenario = test_scenario::begin(ADMIN);
        let ctx = scenario.ctx();
        counter::create(ctx);
        scenario.next_tx(ADMIN);

        // Verify AdminCap was transferred to sender (ADMIN)
        let admin_cap = scenario.take_from_sender<counter::AdminCap>();
        assert!(object::id(&admin_cap).to_address() != @0x0);

        // Verify Counter was shared with initial values
        let counter = test_scenario::take_shared<counter::Counter>(&scenario);
        assert!(counter::count(&counter) == 0);
        assert!(counter::step(&counter) == 1);

        // Cleanup
        test_scenario::return_shared(counter);
        scenario.return_to_sender(admin_cap);
        scenario.end();
    }

    #[test]
    /// Test that incrementing the counter works correctly
    fun increment_counter() {
        let mut scenario = test_scenario::begin(ADMIN);
        let ctx = scenario.ctx();
        counter::create(ctx);
        scenario.next_tx(USER);

        // Increment as USER (anyone can increment a shared object)
        let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
        counter::increment(&mut counter);
        assert!(counter::count(&counter) == 1);
        test_scenario::return_shared(counter);

        scenario.end();
    }

    #[test]
    /// Test that incrementing multiple times accumulates correctly
    fun increment_multiple_times() {
        let mut scenario = test_scenario::begin(ADMIN);
        let ctx = scenario.ctx();
        counter::create(ctx);
        scenario.next_tx(USER);

        // Increment 3 times in the same transaction
        {
            let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
            counter::increment(&mut counter);
            assert!(counter::count(&counter) == 1);
            counter::increment(&mut counter);
            assert!(counter::count(&counter) == 2);
            counter::increment(&mut counter);
            assert!(counter::count(&counter) == 3);
            test_scenario::return_shared(counter);
        };

        scenario.end();
    }

    #[test]
    /// Test that the admin can reset the counter
    fun admin_can_reset() {
        let mut scenario = test_scenario::begin(ADMIN);
        let ctx = scenario.ctx();
        counter::create(ctx);
        scenario.next_tx(ADMIN);

        // Take admin cap and counter, increment twice
        let admin_cap = scenario.take_from_sender<counter::AdminCap>();
        let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
        counter::increment(&mut counter);
        counter::increment(&mut counter);
        assert!(counter::count(&counter) == 2);
        test_scenario::return_shared(counter);
        scenario.return_to_sender(admin_cap);

        // Second transaction: reset using admin cap
        scenario.next_tx(ADMIN);
        let admin_cap = scenario.take_from_sender<counter::AdminCap>();
        let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
        counter::reset(&admin_cap, &mut counter);
        assert!(counter::count(&counter) == 0);
        test_scenario::return_shared(counter);
        scenario.return_to_sender(admin_cap);

        scenario.end();
    }

    #[test]
    /// Test that the admin can change the increment step
    fun admin_can_set_step() {
        let mut scenario = test_scenario::begin(ADMIN);
        let ctx = scenario.ctx();
        counter::create(ctx);
        scenario.next_tx(ADMIN);

        // Set step to 5
        let admin_cap = scenario.take_from_sender<counter::AdminCap>();
        let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
        counter::set_step(&admin_cap, &mut counter, 5);
        assert!(counter::step(&counter) == 5);
        test_scenario::return_shared(counter);
        scenario.return_to_sender(admin_cap);

        // Increment with new step
        scenario.next_tx(ADMIN);
        {
            let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
            counter::increment(&mut counter);
            assert!(counter::count(&counter) == 5);
            counter::increment(&mut counter);
            assert!(counter::count(&counter) == 10);
            test_scenario::return_shared(counter);
        };

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = counter::EUnauthorized)]
    /// Test that a mismatched AdminCap cannot reset the counter
    fun only_admin_can_reset() {
        let mut scenario = test_scenario::begin(ADMIN);
        let ctx = scenario.ctx();
        counter::create(ctx);
        scenario.next_tx(ADMIN);

        // Take the first counter's admin cap and remember its counter_id
        let _first_cap = scenario.take_from_sender<counter::AdminCap>();

        // Take the first counter to remember its ID
        let first_counter = test_scenario::take_shared<counter::Counter>(&scenario);
        let first_counter_id = object::id(&first_counter);
        test_scenario::return_shared(first_counter);
        scenario.return_to_sender(_first_cap);

        // Create a second counter (gets a different AdminCap)
        {
            let ctx = scenario.ctx();
            counter::create(ctx);
        };
        scenario.next_tx(ADMIN);

        // Take the second admin cap
        let _second_cap = scenario.take_from_sender<counter::AdminCap>();

        // Try to use the second cap to reset the first counter.
        // The second cap's counter_id won't match the first counter's id.
        {
            let mut counter = test_scenario::take_shared_by_id<counter::Counter>(&scenario, first_counter_id);
            counter::reset(&_second_cap, &mut counter);
            // This line should not be reached
            test_scenario::return_shared(counter);
        };

        scenario.return_to_sender(_second_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = counter::EUnauthorized)]
    /// Test that a mismatched AdminCap cannot set the step
    fun only_admin_can_set_step() {
        let mut scenario = test_scenario::begin(ADMIN);
        let ctx = scenario.ctx();
        counter::create(ctx);
        scenario.next_tx(ADMIN);

        let _first_cap = scenario.take_from_sender<counter::AdminCap>();

        // Take the first counter to remember its ID
        let first_counter = test_scenario::take_shared<counter::Counter>(&scenario);
        let first_counter_id = object::id(&first_counter);
        test_scenario::return_shared(first_counter);
        scenario.return_to_sender(_first_cap);

        // Create a second counter to get a different AdminCap
        {
            let ctx = scenario.ctx();
            counter::create(ctx);
        };
        scenario.next_tx(ADMIN);

        let _second_cap = scenario.take_from_sender<counter::AdminCap>();

        // Try to set step on the first counter with the second cap
        {
            let mut counter = test_scenario::take_shared_by_id<counter::Counter>(&scenario, first_counter_id);
            counter::set_step(&_second_cap, &mut counter, 100);
            test_scenario::return_shared(counter);
        };

        scenario.return_to_sender(_second_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = counter::EOverflow)]
    /// Test that counter overflow is caught
    fun counter_overflow_protection() {
        let mut scenario = test_scenario::begin(ADMIN);
        let ctx = scenario.ctx();
        counter::create(ctx);
        scenario.next_tx(ADMIN);

        // First increment to count = 1
        let admin_cap = scenario.take_from_sender<counter::AdminCap>();
        let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
        counter::increment(&mut counter);
        assert!(counter::count(&counter) == 1);
        // Now set step to max u64 so count (1) + step (MAX) overflows
        counter::set_step(&admin_cap, &mut counter, 18446744073709551615);
        test_scenario::return_shared(counter);
        scenario.return_to_sender(admin_cap);

        // Now increment - 1 + MAX_U64 overflows, should abort
        scenario.next_tx(USER);
        {
            let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
            counter::increment(&mut counter);
            test_scenario::return_shared(counter);
        };

        scenario.end();
    }

    #[test]
    /// Test get_count and get_step read functions across state changes
    fun read_functions() {
        let mut scenario = test_scenario::begin(ADMIN);
        let ctx = scenario.ctx();
        counter::create(ctx);
        scenario.next_tx(ADMIN);

        // Verify initial state
        let admin_cap = scenario.take_from_sender<counter::AdminCap>();
        let counter = test_scenario::take_shared<counter::Counter>(&scenario);
        assert!(counter::count(&counter) == 0);
        assert!(counter::step(&counter) == 1);
        test_scenario::return_shared(counter);
        scenario.return_to_sender(admin_cap);

        // Increment and check
        scenario.next_tx(ADMIN);
        {
            let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
            counter::increment(&mut counter);
            assert!(counter::count(&counter) == 1);
            test_scenario::return_shared(counter);
        };

        // Change step and increment
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<counter::AdminCap>();
            let mut counter = test_scenario::take_shared<counter::Counter>(&scenario);
            counter::set_step(&admin_cap, &mut counter, 10);
            assert!(counter::step(&counter) == 10);
            counter::increment(&mut counter);
            assert!(counter::count(&counter) == 11);
            test_scenario::return_shared(counter);
            scenario.return_to_sender(admin_cap);
        };

        scenario.end();
    }
