/// Module: object_basics::counter
/// A simple counter contract demonstrating Sui object model basics:
/// - Owned objects (AdminCap)
/// - Shared objects (Counter)
/// - Events and error codes
/// - Object creation, transfer, and sharing

module object_basics::counter {
    use sui::event;
    use sui::object::{Self};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    // ========== Error codes ==========

    /// Raised when a non-admin tries to call a restricted function
    const EUnauthorized: u64 = 0;

    /// Raised when incrementing would overflow the counter value
    const EOverflow: u64 = 1;

    /// Maximum value for u64
    const MAX_U64: u64 = 18446744073709551615;

    // ========== Structs ==========

    /// A shared counter object that anyone can read or increment,
    /// but only the admin can reset or configure.
    public struct Counter has key {
        id: UID,
        count: u64,
        step: u64,
    }

    /// An owned capability object that authorizes admin operations.
    /// Only the creator of a Counter receives the corresponding AdminCap.
    public struct AdminCap has key, store {
        id: UID,
        counter_id: ID,
    }

    // ========== Events ==========

    /// Emitted when a new counter is created
    public struct CounterCreated has copy, drop {
        counter_id: ID,
        admin_cap_id: ID,
    }

    /// Emitted when the counter is incremented
    public struct CounterIncremented has copy, drop {
        counter_id: ID,
        new_count: u64,
    }

    /// Emitted when the counter is reset by an admin
    public struct CounterReset has copy, drop {
        counter_id: ID,
        previous_count: u64,
    }

    /// Emitted when the increment step is changed by an admin
    public struct StepChanged has copy, drop {
        counter_id: ID,
        old_step: u64,
        new_step: u64,
    }

    // ========== Entry functions ==========

    /// Create a new Counter shared object and transfer an AdminCap
    /// to the sender. The Counter starts at count = 0 with step = 1.
    public entry fun create(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);

        // Create the Counter object and record its ID
        let counter_uid = object::new(ctx);
        let counter_id_value = object::uid_to_inner(&counter_uid);
        let counter = Counter {
            id: counter_uid,
            count: 0,
            step: 1,
        };

        // Create the AdminCap, linked to this Counter
        let admin_cap_uid = object::new(ctx);
        let admin_cap_id_value = object::uid_to_inner(&admin_cap_uid);
        let admin_cap = AdminCap {
            id: admin_cap_uid,
            counter_id: counter_id_value,
        };

        // Share the Counter so anyone can interact with it
        transfer::share_object(counter);

        // Transfer the AdminCap to the creator (owned object)
        transfer::transfer(admin_cap, sender);

        // Emit creation event
        event::emit(CounterCreated {
            counter_id: counter_id_value,
            admin_cap_id: admin_cap_id_value,
        });
    }

    /// Increment the counter by the configured step.
    /// Anyone can call this since Counter is a shared object.
    public entry fun increment(counter: &mut Counter) {
        let current = counter.count;
        let step = counter.step;
        // Overflow check: step must not exceed (MAX_U64 - current)
        assert!(step <= MAX_U64 - current, EOverflow);

        counter.count = current + step;

        event::emit(CounterIncremented {
            counter_id: object::uid_to_inner(&counter.id),
            new_count: counter.count,
        });
    }

    /// Reset the counter back to zero. Only the admin can do this.
    public entry fun reset(
        cap: &AdminCap,
        counter: &mut Counter,
    ) {
        // Verify that this AdminCap is authorized for this Counter
        assert!(cap.counter_id == object::uid_to_inner(&counter.id), EUnauthorized);

        let previous_count = counter.count;
        counter.count = 0;

        event::emit(CounterReset {
            counter_id: object::uid_to_inner(&counter.id),
            previous_count,
        });
    }

    /// Change the increment step. Only the admin can do this.
    public entry fun set_step(
        cap: &AdminCap,
        counter: &mut Counter,
        new_step: u64,
    ) {
        // Verify that this AdminCap is authorized for this Counter
        assert!(cap.counter_id == object::uid_to_inner(&counter.id), EUnauthorized);

        let old_step = counter.step;
        counter.step = new_step;

        event::emit(StepChanged {
            counter_id: object::uid_to_inner(&counter.id),
            old_step,
            new_step,
        });
    }

    // ========== Read-only functions ==========

    /// Get the current count value (can be called as a move call)
    public fun get_count(counter: &Counter): u64 {
        counter.count
    }

    /// Get the current step value
    public fun get_step(counter: &Counter): u64 {
        counter.step
    }

    // ========== Test helpers ==========

    /// Destroy a Counter object (test only)
    #[test_only]
    public fun destroy_counter(counter: Counter) {
        let Counter { id, count: _, step: _ } = counter;
        id.delete();
    }

    /// Destroy an AdminCap object (test only)
    #[test_only]
    public fun destroy_admin_cap(cap: AdminCap) {
        let AdminCap { id, counter_id: _ } = cap;
        id.delete();
    }
}
