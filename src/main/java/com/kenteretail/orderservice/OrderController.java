package com.kenteretail.orderservice;

import com.kenteretail.orderservice.model.Order;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

@RestController
public class OrderController {

    // Starting point high enough that seeded/demo orders don't collide with
    // the two fixture orders returned by listOrders() below (ORD-1001/1002) --
    // the first generated ID is this value PLUS ONE, so start at 2000, not 1000.
    private final AtomicInteger sequence = new AtomicInteger(2000);

    private static final List<Order> FIXTURES = List.of(
            new Order("ORD-1001", "kente-cloth-wrap", 2),
            new Order("ORD-1002", "kente-cloth-scarf", 1)
    );

    @GetMapping("/health")
    public String health() {
        return "OK";
    }

    @GetMapping("/api/orders")
    public List<Order> listOrders() {
        return FIXTURES;
    }

    @GetMapping("/api/orders/{id}")
    public Order getOrder(@PathVariable String id) {
        return FIXTURES.stream()
                .filter(o -> o.getId().equals(id))
                .findFirst()
                .orElseThrow(() -> new OrderNotFoundException(id));
    }

    @PostMapping("/api/orders")
    public Order createOrder(@RequestBody OrderRequest request) {
        String id = "ORD-" + sequence.incrementAndGet();
        return new Order(id, request.item(), request.quantity());
    }

    public record OrderRequest(String item, int quantity) {
    }
}
