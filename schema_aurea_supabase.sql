-- ============================================================================
-- AUREA – SISTEMA DE INFORMACIÓN PARA LIBRERÍA
-- Esquema Completo para Supabase / PostgreSQL (Tablas, Índices, RLS y RPC)
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL,
  email TEXT UNIQUE NOT NULL,
  role TEXT NOT NULL DEFAULT 'vendedor' CHECK (role IN ('admin', 'vendedor')),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.authors (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT UNIQUE NOT NULL,
  nationality TEXT,
  biography TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.categories (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT UNIQUE NOT NULL,
  description TEXT,
  color_hex TEXT DEFAULT '#7c3aed',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.books (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  isbn TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL,
  author_id UUID NOT NULL REFERENCES public.authors(id) ON DELETE RESTRICT,
  category_id UUID NOT NULL REFERENCES public.categories(id) ON DELETE RESTRICT,
  editorial TEXT DEFAULT 'Aurea Ediciones',
  pub_year INTEGER DEFAULT 2024,
  price NUMERIC(10, 2) NOT NULL CHECK (price >= 0),
  stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
  min_stock INTEGER NOT NULL DEFAULT 5 CHECK (min_stock >= 0),
  cover_color TEXT DEFAULT '#1a1535',
  cover_url TEXT,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.customers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  document_id TEXT UNIQUE NOT NULL,
  full_name TEXT NOT NULL,
  email TEXT UNIQUE,
  phone TEXT,
  address TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.sales (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  receipt_number TEXT UNIQUE NOT NULL,
  customer_id UUID REFERENCES public.customers(id) ON DELETE SET NULL,
  seller_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  seller_name TEXT NOT NULL,
  subtotal NUMERIC(10, 2) NOT NULL CHECK (subtotal >= 0),
  discount NUMERIC(10, 2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  tax NUMERIC(10, 2) NOT NULL DEFAULT 0 CHECK (tax >= 0),
  total NUMERIC(10, 2) NOT NULL CHECK (total >= 0),
  payment_method TEXT NOT NULL DEFAULT 'Efectivo',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.sale_details (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sale_id UUID NOT NULL REFERENCES public.sales(id) ON DELETE CASCADE,
  book_id UUID NOT NULL REFERENCES public.books(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price >= 0),
  subtotal NUMERIC(10, 2) NOT NULL CHECK (subtotal >= 0)
);

CREATE TABLE IF NOT EXISTS public.inventory_movements (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  book_id UUID NOT NULL REFERENCES public.books(id) ON DELETE CASCADE,
  movement_type TEXT NOT NULL CHECK (movement_type IN ('ENTRADA', 'SALIDA_VENTA', 'AJUSTE', 'MERMA')),
  quantity INTEGER NOT NULL,
  previous_stock INTEGER NOT NULL,
  new_stock INTEGER NOT NULL,
  reason TEXT NOT NULL,
  user_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ÍNDICES DE RENDIMIENTO
CREATE INDEX IF NOT EXISTS idx_books_title ON public.books(title);
CREATE INDEX IF NOT EXISTS idx_books_isbn ON public.books(isbn);
CREATE INDEX IF NOT EXISTS idx_books_author ON public.books(author_id);
CREATE INDEX IF NOT EXISTS idx_books_category ON public.books(category_id);
CREATE INDEX IF NOT EXISTS idx_sales_created_at ON public.sales(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sales_customer ON public.sales(customer_id);
CREATE INDEX IF NOT EXISTS idx_sale_details_sale ON public.sale_details(sale_id);
CREATE INDEX IF NOT EXISTS idx_inv_mov_book ON public.inventory_movements(book_id);

-- POLÍTICAS DE SEGURIDAD RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.authors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.books ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin' AND active = TRUE
  );
$$ LANGUAGE sql SECURITY DEFINER;

CREATE POLICY "Lectura general autenticada" ON public.books FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "Lectura autores" ON public.authors FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "Lectura categorias" ON public.categories FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "Lectura clientes" ON public.customers FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "Lectura ventas" ON public.sales FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "Lectura detalles venta" ON public.sale_details FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "Lectura movimientos" ON public.inventory_movements FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "Admin gestiona libros" ON public.books FOR ALL TO authenticated USING (public.is_admin());
CREATE POLICY "Admin gestiona autores" ON public.authors FOR ALL TO authenticated USING (public.is_admin());
CREATE POLICY "Admin gestiona categorias" ON public.categories FOR ALL TO authenticated USING (public.is_admin());
CREATE POLICY "Personal gestiona clientes" ON public.customers FOR ALL TO authenticated USING (TRUE);
CREATE POLICY "Personal registra ventas" ON public.sales FOR INSERT TO authenticated WITH CHECK (TRUE);
CREATE POLICY "Personal registra detalles" ON public.sale_details FOR INSERT TO authenticated WITH CHECK (TRUE);
CREATE POLICY "Personal registra movimientos" ON public.inventory_movements FOR INSERT TO authenticated WITH CHECK (TRUE);

-- FUNCIÓN TRANSACCIONAL SEGURA PARA VENTAS
CREATE OR REPLACE FUNCTION public.registrar_venta_segura(
  p_receipt_number TEXT, p_customer_id UUID, p_seller_id UUID, p_seller_name TEXT,
  p_discount NUMERIC, p_tax NUMERIC, p_payment_method TEXT, p_items JSONB
) RETURNS UUID AS $$
DECLARE
  v_sale_id UUID; v_subtotal NUMERIC(10,2) := 0; v_total NUMERIC(10,2) := 0;
  v_item JSONB; v_book_id UUID; v_qty INTEGER; v_price NUMERIC(10,2);
  v_curr_stock INTEGER; v_book_title TEXT;
BEGIN
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_book_id := (v_item->>'book_id')::UUID;
    v_qty := (v_item->>'quantity')::INTEGER;
    v_price := (v_item->>'unit_price')::NUMERIC;
    SELECT stock, title INTO v_curr_stock, v_book_title FROM public.books WHERE id = v_book_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Libro no encontrado: %', v_book_id; END IF;
    IF v_curr_stock < v_qty THEN RAISE EXCEPTION 'Stock insuficiente para "%"', v_book_title; END IF;
    v_subtotal := v_subtotal + (v_qty * v_price);
  END LOOP;

  v_total := GREATEST(0, v_subtotal - COALESCE(p_discount, 0) + COALESCE(p_tax, 0));

  INSERT INTO public.sales (receipt_number, customer_id, seller_id, seller_name, subtotal, discount, tax, total, payment_method)
  VALUES (p_receipt_number, p_customer_id, p_seller_id, p_seller_name, v_subtotal, COALESCE(p_discount, 0), COALESCE(p_tax, 0), v_total, p_payment_method)
  RETURNING id INTO v_sale_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_book_id := (v_item->>'book_id')::UUID;
    v_qty := (v_item->>'quantity')::INTEGER;
    v_price := (v_item->>'unit_price')::NUMERIC;
    SELECT stock INTO v_curr_stock FROM public.books WHERE id = v_book_id;

    INSERT INTO public.sale_details (sale_id, book_id, quantity, unit_price, subtotal)
    VALUES (v_sale_id, v_book_id, v_qty, v_price, v_qty * v_price);

    UPDATE public.books SET stock = v_curr_stock - v_qty, updated_at = NOW() WHERE id = v_book_id;

    INSERT INTO public.inventory_movements (book_id, movement_type, quantity, previous_stock, new_stock, reason, user_name)
    VALUES (v_book_id, 'SALIDA_VENTA', -v_qty, v_curr_stock, v_curr_stock - v_qty, 'Venta ' || p_receipt_number, p_seller_name);
  END LOOP;

  RETURN v_sale_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;