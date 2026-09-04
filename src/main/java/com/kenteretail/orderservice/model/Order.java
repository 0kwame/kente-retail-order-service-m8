package com.kenteretail.orderservice.model;

public class Order {

    private final String id;
    private final String item;
    private final int quantity;

    public Order(String id, String item, int quantity) {
        this.id = id;
        this.item = item;
        this.quantity = quantity;
    }

    public String getId() {
        return id;
    }

    public String getItem() {
        return item;
    }

    public int getQuantity() {
        return quantity;
    }

    // Kente Retail prices in cedis. Constant for now -- multi-currency is a
    // later ticket; this exists so a release is visible in the response body.
    public String getCurrency() {
        return "GHS";
    }
}
