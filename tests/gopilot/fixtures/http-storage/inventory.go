package main

type Inventory struct {
	stock map[string]int
}

func NewInventory(stock map[string]int) *Inventory {
	return &Inventory{stock: stock}
}

func (i *Inventory) Reserve(sku string, qty int) bool {
	if qty <= 0 || i.stock[sku] < qty {
		return false
	}
	i.stock[sku] -= qty
	return true
}
