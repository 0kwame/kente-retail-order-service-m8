package com.kenteretail.orderservice;

import com.kenteretail.orderservice.model.Order;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class OrderControllerTest {

    private final OrderController controller = new OrderController();

    @Test
    void healthReturnsOk() {
        assertEquals("OK", controller.health());
    }

    @Test
    void listOrdersReturnsSeedFixtures() {
        List<Order> orders = controller.listOrders();
        assertEquals(2, orders.size());
    }

    @Test
    void createOrderAssignsAGeneratedId() {
        Order order = controller.createOrder(new OrderController.OrderRequest("kente-cloth-runner", 3));
        assertNotNull(order.getId());
        assertTrue(order.getId().startsWith("ORD-"));
    }

    // Replaces the seeded placeholderRegressionCheck(). The sequence in
    // OrderController starts above the fixture range on purpose; nothing was
    // defending that. This is the assertion the checkout-fix ticket needed:
    // a generated ID must never be an ID listOrders() already hands out.
    @Test
    void generatedIdsNeverCollideWithSeedFixtures() {
        Set<String> fixtureIds = controller.listOrders().stream()
                .map(Order::getId)
                .collect(Collectors.toSet());

        for (int i = 0; i < 5; i++) {
            Order created = controller.createOrder(new OrderController.OrderRequest("kente-cloth-wrap", 1));
            assertFalse(fixtureIds.contains(created.getId()),
                    "generated order ID collided with a seed fixture: " + created.getId());
        }
    }

    @Test
    void generatedIdsAreUnique() {
        Set<String> seen = IntStream.range(0, 50)
                .mapToObj(i -> controller.createOrder(
                        new OrderController.OrderRequest("kente-cloth-scarf", 1)).getId())
                .collect(Collectors.toSet());

        assertEquals(50, seen.size(), "sequence handed out a duplicate order ID");
    }
}
