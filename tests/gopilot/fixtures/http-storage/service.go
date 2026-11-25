package main

import (
	"context"
	"errors"
	"fmt"
)

var ErrOutOfStock = errors.New("out of stock")

type CreateOrderRequest struct {
	SKU string `json:"sku"`
	Qty int    `json:"qty"`
}

type Order struct {
	ID  string `json:"id"`
	SKU string `json:"sku"`
	Qty int    `json:"qty"`
}

type Repository interface {
	Save(ctx context.Context, o Order) error
}

type Service struct {
	repo      Repository
	inventory *Inventory
	next      int
}

func NewService(repo Repository, inv *Inventory) *Service {
	return &Service{repo: repo, inventory: inv}
}

func (s *Service) Create(ctx context.Context, req CreateOrderRequest) (Order, error) {
	if !s.inventory.Reserve(req.SKU, req.Qty) {
		return Order{}, ErrOutOfStock
	}
	s.next++
	order := Order{ID: fmt.Sprintf("o-%d", s.next), SKU: req.SKU, Qty: req.Qty}
	if err := s.repo.Save(ctx, order); err != nil {
		return Order{}, fmt.Errorf("save order: %w", err)
	}
	return order, nil
}
