import os, sys, textwrap

root = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 12
MOD = "stressmod"

def w(rel, s):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(textwrap.dedent(s).lstrip())

w("go.mod", f"""
module {MOD}

go 1.25.0

require (
\tgithub.com/google/uuid v1.6.0
\tgo.uber.org/zap v1.27.0
\tgolang.org/x/sync v0.22.0
)

require go.uber.org/multierr v1.11.0 // indirect
""")
w("go.sum", """
github.com/davecgh/go-spew v1.1.1 h1:vj9j/u1bqnvCEfJOwUhtlOARqs3+rkHYY13jYWTU97c=
github.com/davecgh/go-spew v1.1.1/go.mod h1:J7Y8YcW2NihsgmVo/mv3lAwl/skON4iLHjSsI+c5H38=
github.com/google/uuid v1.6.0 h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
github.com/google/uuid v1.6.0/go.mod h1:TIyPZe4MgqvfeYDBFedMoGGpEw/LqOeaOT+nhxU+yHo=
github.com/pmezard/go-difflib v1.0.0 h1:4DBwDE0NGyQoBHbLQYPwSUPoCMWR5BEzIk/f1lZbAQM=
github.com/pmezard/go-difflib v1.0.0/go.mod h1:iKH77koFhYxTK1pcRnkKkqfTogsbg7gZNVY4sRDYZ/4=
github.com/stretchr/testify v1.8.1 h1:w7B6lhMri9wdJUVmEZPGGhZzrYTPvgJArz7wNPgYKsk=
github.com/stretchr/testify v1.8.1/go.mod h1:w2LPCIKwWwSfY2zedu0+kehJoqGctiVI29o6fzry7u4=
go.uber.org/goleak v1.3.0 h1:2K3zAYmnTNqV73imy9J1T3WC+gmCePx2hEGkimedGto=
go.uber.org/goleak v1.3.0/go.mod h1:CoHD4mav9JJNrW/WLlf7HGZPjdw8EucARQHekz1X6bE=
go.uber.org/multierr v1.11.0 h1:blXXJkSxSSfBVBlC76pxqeO+LN3aDfLQo+309xJstO0=
go.uber.org/multierr v1.11.0/go.mod h1:20+QtiLqy0Nd6FdQB9TLXag12DsQkrbs3htMFfDN80Y=
go.uber.org/zap v1.27.0 h1:aJMhYGrd5QSmlpLMr2MftRKl7t8J8PTZPA732ud/XR8=
go.uber.org/zap v1.27.0/go.mod h1:GB2qFLM7cTU87MWRP2mPIjqfIDnGu+VIO4V/SdhGo2E=
golang.org/x/sync v0.22.0 h1:SZjpbeLmrCk4xhRSZFNZW5gFUeCeFgjekvI/+gfScek=
golang.org/x/sync v0.22.0/go.mod h1:9xrNwdLfx4jkKbNva9FpL6vEN7evnE43NNNJQ2LF3+0=
gopkg.in/yaml.v3 v3.0.1 h1:fxVm/GzAzEWqLHuvctI91KS9hhNmmWOoWu0XTYJS7CA=
gopkg.in/yaml.v3 v3.0.1/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
""")

for k in range(8):
    imp = f'\t"{MOD}/util/u{k-1}"\n' if k else ""
    use = f"\treturn u{k-1}.Chain{k-1}(s+\"{k}\", n+1)\n" if k else "\treturn strings.Repeat(s, n%3+1)\n"
    w(f"util/u{k}/u.go", f"""
package u{k}

import (
\t"strings"
{imp})

func Chain{k}(s string, n int) string {{
{use}}}

func Keys{k}[K comparable, V any](m map[K]V) []K {{
\tout := make([]K, 0, len(m))
\tfor key := range m {{
\t\tout = append(out, key)
\t}}
\treturn out
}}

func Clamp{k}[T ~int | ~int64 | ~float64](v, lo, hi T) T {{
\tif v < lo {{
\t\treturn lo
\t}}
\tif v > hi {{
\t\treturn hi
\t}}
\treturn v
}}

var _ = strings.TrimSpace
""")

w("core/entity.go", f"""
package core

import (
\t"context"
\t"errors"
\t"fmt"
\t"time"

\t"github.com/google/uuid"
\t"{MOD}/util/u7"
)

type ID string

func NewID() ID {{ return ID(uuid.NewString()) }}

func (id ID) String() string {{ return string(id) }}

type Entity interface {{
\tGetID() ID
\tKind() string
\tValidate() error
\tTouch(at time.Time)
}}

type Base struct {{
\tID        ID
\tCreatedAt time.Time
\tUpdatedAt time.Time
\tVersion   int
\tOwner     ID
\tTenant    ID
\tTags      []string
\tMeta      map[string]string
\tDeleted   bool
}}

func (b *Base) GetID() ID {{ return b.ID }}

func (b *Base) Touch(at time.Time) {{
\tb.UpdatedAt = at
\tb.Version++
}}

func (b *Base) Label() string {{ return u7.Chain7(string(b.ID), b.Version) }}

var ErrNotFound = errors.New("not found")
var ErrInvalid = errors.New("invalid")

type ValidationError struct {{
\tField  string
\tReason string
}}

func (e *ValidationError) Error() string {{ return fmt.Sprintf("%s: %s", e.Field, e.Reason) }}

type Filter struct {{
\tLimit   int
\tOffset  int
\tOrderBy string
\tTenant  ID
\tWhere   map[string]any
\tSince   time.Time
}}

type Repository[T Entity] interface {{
\tGet(ctx context.Context, id ID) (T, error)
\tList(ctx context.Context, f Filter) ([]T, error)
\tSave(ctx context.Context, v T) error
\tDelete(ctx context.Context, id ID) error
\tCount(ctx context.Context, f Filter) (int, error)
}}
""")

w("core/service.go", f"""
package core

import (
\t"context"
\t"time"

\t"go.uber.org/zap"
)

type Service interface {{
\tName() string
\tStart(ctx context.Context) error
\tStop(ctx context.Context) error
\tHealth(ctx context.Context) Health
}}

type Health struct {{
\tOK      bool
\tDetail  string
\tChecked time.Time
}}

type Config struct {{
\tName           string
\tEnv            string
\tTenant         ID
\tMaxItems       int
\tBatchSize      int
\tTimeout        time.Duration
\tRetryLimit     int
\tRetryBackoff   time.Duration
\tFeatureFlags   map[string]bool
\tRegion         string
\tReadOnly       bool
\tAuditEnabled   bool
\tCacheTTL       time.Duration
\tPageSize       int
\tWorkerCount    int
\tQueueName      string
\tDatabaseURL    string
\tStorageBucket  string
\tMetricsPrefix  string
\tDefaultLocale  string
}}

type Deps struct {{
\tLog    *zap.Logger
\tConfig Config
\tBus    Bus
\tClock  func() time.Time
}}

func NewDeps(name string, cfg Config) Deps {{
\treturn Deps{{Log: NewLogger(name), Config: cfg, Bus: NewMemoryBus(), Clock: time.Now}}
}}

func NewLogger(name string) *zap.Logger {{
\treturn zap.NewNop().Named(name)
}}
""")

w("core/events.go", """
package core

import (
\t"context"
\t"sync"
\t"time"
)

type Event struct {
\tTopic   string
\tSubject ID
\tAt      time.Time
\tPayload map[string]any
}

type Handler func(ctx context.Context, e Event) error

type Bus interface {
\tPublish(ctx context.Context, e Event) error
\tSubscribe(topic string, h Handler)
}

type memoryBus struct {
\tmu   sync.RWMutex
\tsubs map[string][]Handler
}

func NewMemoryBus() Bus { return &memoryBus{subs: map[string][]Handler{}} }

func (b *memoryBus) Publish(ctx context.Context, e Event) error {
\tb.mu.RLock()
\ths := append([]Handler(nil), b.subs[e.Topic]...)
\tb.mu.RUnlock()
\tfor _, h := range hs {
\t\tif err := h(ctx, e); err != nil {
\t\t\treturn err
\t\t}
\t}
\treturn nil
}

func (b *memoryBus) Subscribe(topic string, h Handler) {
\tb.mu.Lock()
\tb.subs[topic] = append(b.subs[topic], h)
\tb.mu.Unlock()
}
""")

w("core/generic.go", """
package core

import "sort"

type Result[T any] struct {
\tValue T
\tErr   error
}

func Ok[T any](v T) Result[T] { return Result[T]{Value: v} }

func Map[T, U any](in []T, f func(T) U) []U {
\tout := make([]U, 0, len(in))
\tfor _, v := range in {
\t\tout = append(out, f(v))
\t}
\treturn out
}

func Where[T any](in []T, keep func(T) bool) []T {
\tvar out []T
\tfor _, v := range in {
\t\tif keep(v) {
\t\t\tout = append(out, v)
\t\t}
\t}
\treturn out
}

func GroupBy[T any, K comparable](in []T, key func(T) K) map[K][]T {
\tout := map[K][]T{}
\tfor _, v := range in {
\t\tk := key(v)
\t\tout[k] = append(out[k], v)
\t}
\treturn out
}

func SortBy[T any, K int | string | float64](in []T, key func(T) K) {
\tsort.Slice(in, func(i, j int) bool { return key(in[i]) < key(in[j]) })
}

type Page[T Entity] struct {
\tItems []T
\tTotal int
\tNext  *Filter
}

func Must[T any](v T, err error) T {
\tif err != nil {
\t\tpanic(err)
\t}
\treturn v
}
""")

kinds = ["Order", "Course", "Lesson", "Invoice", "Student", "Teacher", "Quiz", "Badge", "Room", "Report", "Ticket", "Plan", "Asset", "Grade", "Topic", "Media"]
def kind(i): return kinds[i % len(kinds)] + (str(i // len(kinds)) if i >= len(kinds) else "")

for i in range(N):
    K = kind(i)
    prev = f'\tprev "{MOD}/domain/d{i-1}"\n' if i else ""
    prevfield = f"\tParent   *prev.{kind(i-1)}\n\tSiblings []prev.{kind(i-1)}Line\n" if i else ""
    prevval = f"\tif x.Parent != nil {{\n\t\tif err := x.Parent.Validate(); err != nil {{\n\t\t\treturn err\n\t\t}}\n\t}}\n" if i else ""
    w(f"domain/d{i}/model.go", f"""
package d{i}

import (
\t"strings"
\t"time"

\t"{MOD}/core"
{prev})

type Status int

const (
\tStatusDraft Status = iota
\tStatusActive
\tStatusArchived
)

type {K} struct {{
\tcore.Base
\tTitle    string
\tAmount   int64
\tStatus   Status
\tDueAt    time.Time
\tLines    []{K}Line
{prevfield}}}

type {K}Line struct {{
\tcore.Base
\tSKU      string
\tQuantity int
\tPrice    int64
}}

func (x *{K}) Kind() string {{ return "{K.lower()}" }}

func (x *{K}) Validate() error {{
\tif strings.TrimSpace(x.Title) == "" {{
\t\treturn &core.ValidationError{{Field: "Title", Reason: "empty"}}
\t}}
\tif x.Amount < 0 {{
\t\treturn core.ErrInvalid
\t}}
{prevval}\treturn nil
}}

func (l *{K}Line) Kind() string {{ return "{K.lower()}-line" }}

func (l *{K}Line) Validate() error {{
\tif l.Quantity <= 0 {{
\t\treturn core.ErrInvalid
\t}}
\treturn nil
}}

func (x *{K}) Total() int64 {{
\tvar t int64
\tfor _, l := range x.Lines {{
\t\tt += int64(l.Quantity) * l.Price
\t}}
\treturn t
}}

func New{K}(title string, owner core.ID) *{K} {{
\tnow := time.Now()
\treturn &{K}{{Base: core.Base{{ID: core.NewID(), CreatedAt: now, UpdatedAt: now, Owner: owner}}, Title: title}}
}}
""")
    w(f"domain/d{i}/query.go", f"""
package d{i}

import "{MOD}/core"

func Active(in []*{K}) []*{K} {{
\treturn core.Where(in, func(x *{K}) bool {{ return x.Status == StatusActive && !x.Deleted }})
}}

func Titles(in []*{K}) []string {{
\treturn core.Map(in, func(x *{K}) string {{ return x.Title }})
}}

func ByOwner(in []*{K}) map[core.ID][]*{K} {{
\treturn core.GroupBy(in, func(x *{K}) core.ID {{ return x.Owner }})
}}

func Newest(in []*{K}) {{
\tcore.SortBy(in, func(x *{K}) int {{ return -int(x.UpdatedAt.Unix()) }})
}}
""")

for i in range(N):
    K = kind(i)
    j = (i * 5 + 3) % N
    Kj = kind(j)
    other = f'\tdj "{MOD}/domain/d{j}"\n' if j != i else ""
    otherfn = f"""
func (r *{K}Repo) Related(ctx context.Context, x *d{i}.{K}) []*dj.{Kj} {{
\t_ = ctx
\tvar out []*dj.{Kj}
\tfor _, id := range x.Tags {{
\t\tout = append(out, dj.New{Kj}(id, x.Owner))
\t}}
\treturn out
}}
""" if j != i else ""
    w(f"repo/r{i}/repo.go", f"""
package r{i}

import (
\t"context"
\t"sync"
\t"time"

\t"{MOD}/core"
\t"{MOD}/domain/d{i}"
{other}\t"{MOD}/util/u3"
)

type {K}Repo struct {{
\tmu    sync.RWMutex
\titems map[core.ID]*d{i}.{K}
\tdeps  core.Deps
}}

var _ core.Repository[*d{i}.{K}] = (*{K}Repo)(nil)

func New(deps core.Deps) *{K}Repo {{
\treturn &{K}Repo{{items: map[core.ID]*d{i}.{K}{{}}, deps: deps}}
}}

func (r *{K}Repo) Get(ctx context.Context, id core.ID) (*d{i}.{K}, error) {{
\tr.mu.RLock()
\tdefer r.mu.RUnlock()
\tif v, ok := r.items[id]; ok && !v.Deleted {{
\t\treturn v, nil
\t}}
\treturn nil, core.ErrNotFound
}}

func (r *{K}Repo) List(ctx context.Context, f core.Filter) ([]*d{i}.{K}, error) {{
\tr.mu.RLock()
\tdefer r.mu.RUnlock()
\tvar out []*d{i}.{K}
\tfor _, v := range r.items {{
\t\tif f.Tenant != "" && v.Tenant != f.Tenant {{
\t\t\tcontinue
\t\t}}
\t\tif !f.Since.IsZero() && v.UpdatedAt.Before(f.Since) {{
\t\t\tcontinue
\t\t}}
\t\tout = append(out, v)
\t}}
\td{i}.Newest(out)
\tif f.Limit > 0 && len(out) > f.Limit {{
\t\tout = out[:u3.Clamp3(f.Limit, 0, len(out))]
\t}}
\treturn out, nil
}}

func (r *{K}Repo) Save(ctx context.Context, v *d{i}.{K}) error {{
\tif err := v.Validate(); err != nil {{
\t\treturn err
\t}}
\tv.Touch(time.Now())
\tr.mu.Lock()
\tr.items[v.ID] = v
\tr.mu.Unlock()
\treturn r.deps.Bus.Publish(ctx, core.Event{{Topic: "{K.lower()}.saved", Subject: v.ID, At: v.UpdatedAt}})
}}

func (r *{K}Repo) Delete(ctx context.Context, id core.ID) error {{
\tr.mu.Lock()
\tdefer r.mu.Unlock()
\tif v, ok := r.items[id]; ok {{
\t\tv.Deleted = true
\t\treturn nil
\t}}
\treturn core.ErrNotFound
}}

func (r *{K}Repo) Count(ctx context.Context, f core.Filter) (int, error) {{
\titems, err := r.List(ctx, f)
\treturn len(items), err
}}
{otherfn}""")

for i in range(N):
    K = kind(i)
    deps = sorted({j for j in [i - 1, i - 2, (i * 7 + 1) % N] if 0 <= j < i})
    j2 = (i + 1) % N
    imports = [f'\t"{MOD}/core"', f'\t"{MOD}/domain/d{i}"', f'\t"{MOD}/repo/r{i}"']
    if j2 != i:
        imports.append(f'\trj "{MOD}/repo/r{j2}"')
    for d in deps:
        imports.append(f'\t"{MOD}/service/s{d}"')
    fields = "".join(f"\tS{d} *s{d}.Service\n" for d in deps)
    newargs = "".join(f", s{d}svc *s{d}.Service" for d in deps)
    assign = "".join(f"\t\tS{d}: s{d}svc,\n" for d in deps)
    rjfield = f"\tRelated *rj.{kind(j2)}Repo\n" if j2 != i else ""
    rjassign = f"\t\tRelated: rj.New(deps),\n" if j2 != i else ""
    calls = "".join(f"\tif s.S{d} != nil {{\n\t\tif _, err := s.S{d}.Summary(ctx, f); err != nil {{\n\t\t\treturn Summary{{}}, err\n\t\t}}\n\t}}\n" for d in deps)
    w(f"service/s{i}/service.go", f"""
package s{i}

import (
\t"context"
\t"fmt"
\t"time"

\t"go.uber.org/zap"
\t"golang.org/x/sync/errgroup"
{chr(10).join(imports)}
)

type Service struct {{
\tdeps  core.Deps
\trepo  *r{i}.{K}Repo
{rjfield}{fields}\tstarted time.Time
}}

var _ core.Service = (*Service)(nil)

type Summary struct {{
\tCount   int
\tActive  int
\tTotal   int64
\tTitles  []string
\tUpdated time.Time
}}

func New(deps core.Deps{newargs}) *Service {{
\treturn &Service{{
\t\tdeps: deps,
\t\trepo: r{i}.New(deps),
{rjassign}{assign}\t}}
}}

func (s *Service) Name() string {{ return "s{i}" }}

func (s *Service) Start(ctx context.Context) error {{
\ts.started = s.deps.Clock()
\ts.deps.Log.Info("start", zap.String("svc", s.Name()), zap.Int("workers", s.deps.Config.WorkerCount))
\ts.deps.Bus.Subscribe("{K.lower()}.saved", func(ctx context.Context, e core.Event) error {{
\t\ts.deps.Log.Debug("saved", zap.String("id", string(e.Subject)))
\t\treturn nil
\t}})
\treturn nil
}}

func (s *Service) Stop(ctx context.Context) error {{ return nil }}

func (s *Service) Health(ctx context.Context) core.Health {{
\treturn core.Health{{OK: !s.started.IsZero(), Detail: s.deps.Config.Region, Checked: s.deps.Clock()}}
}}

func (s *Service) Create(ctx context.Context, title string, owner core.ID, lines ...d{i}.{K}Line) (*d{i}.{K}, error) {{
\tif s.deps.Config.ReadOnly {{
\t\treturn nil, fmt.Errorf("%s: read only", s.Name())
\t}}
\tx := d{i}.New{K}(title, owner)
\tx.Tenant = s.deps.Config.Tenant
\tx.Lines = append(x.Lines, lines...)
\tif len(x.Lines) > s.deps.Config.MaxItems && s.deps.Config.MaxItems > 0 {{
\t\treturn nil, &core.ValidationError{{Field: "Lines", Reason: "too many"}}
\t}}
\tif err := s.repo.Save(ctx, x); err != nil {{
\t\treturn nil, err
\t}}
\treturn x, nil
}}

func (s *Service) Summary(ctx context.Context, f core.Filter) (Summary, error) {{
\tif f.Limit == 0 {{
\t\tf.Limit = s.deps.Config.PageSize
\t}}
\titems, err := s.repo.List(ctx, f)
\tif err != nil {{
\t\treturn Summary{{}}, err
\t}}
{calls}\tsum := Summary{{Count: len(items), Titles: d{i}.Titles(items)}}
\tfor _, x := range d{i}.Active(items) {{
\t\tsum.Active++
\t\tsum.Total += x.Total()
\t\tif x.UpdatedAt.After(sum.Updated) {{
\t\t\tsum.Updated = x.UpdatedAt
\t\t}}
\t}}
\treturn sum, nil
}}

func (s *Service) Bulk(ctx context.Context, titles []string, owner core.ID) ([]*d{i}.{K}, error) {{
\tg, gctx := errgroup.WithContext(ctx)
\tg.SetLimit(s.deps.Config.WorkerCount + 1)
\tout := make([]*d{i}.{K}, len(titles))
\tfor n, t := range titles {{
\t\tg.Go(func() error {{
\t\t\tx, err := s.Create(gctx, t, owner)
\t\t\tout[n] = x
\t\t\treturn err
\t\t}})
\t}}
\treturn out, g.Wait()
}}

func (s *Service) Page(ctx context.Context, f core.Filter) (core.Page[*d{i}.{K}], error) {{
\titems, err := s.repo.List(ctx, f)
\tif err != nil {{
\t\treturn core.Page[*d{i}.{K}]{{}}, err
\t}}
\tnext := f
\tnext.Offset += len(items)
\treturn core.Page[*d{i}.{K}]{{Items: items, Total: len(items), Next: &next}}, nil
}}
""")

for i in range(N):
    K = kind(i)
    w(f"api/a{i}/handlers.go", f"""
package a{i}

import (
\t"context"
\t"encoding/json"
\t"net/http"
\t"strconv"

\t"{MOD}/core"
\t"{MOD}/service/s{i}"
)

type Handler struct {{
\tsvc  *s{i}.Service
\tdeps core.Deps
}}

func New(svc *s{i}.Service, deps core.Deps) *Handler {{ return &Handler{{svc: svc, deps: deps}} }}

func (h *Handler) Register(mux *http.ServeMux) {{
\tmux.HandleFunc("/{K.lower()}s", h.list)
\tmux.HandleFunc("/{K.lower()}s/new", h.create)
}}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {{
\tlimit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
\tsum, err := h.svc.Summary(r.Context(), core.Filter{{Limit: limit, Tenant: h.deps.Config.Tenant}})
\tif err != nil {{
\t\thttp.Error(w, err.Error(), http.StatusInternalServerError)
\t\treturn
\t}}
\t_ = json.NewEncoder(w).Encode(sum)
}}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {{
\tx, err := h.svc.Create(context.WithoutCancel(r.Context()), r.FormValue("title"), core.ID(r.FormValue("owner")))
\tif err != nil {{
\t\thttp.Error(w, err.Error(), http.StatusBadRequest)
\t\treturn
\t}}
\t_ = json.NewEncoder(w).Encode(x)
}}
""")

lines = ["package main", "", "import (", '\t"context"', '\t"net/http"', "", f'\t"{MOD}/core"']
for i in range(N):
    lines.append(f'\t"{MOD}/api/a{i}"')
    lines.append(f'\t"{MOD}/service/s{i}"')
lines += [")", "", "func main() {", '\tdeps := core.NewDeps("server", core.Config{Name: "server", PageSize: 50, WorkerCount: 4})', "\tmux := http.NewServeMux()", "\tctx := context.Background()"]
for i in range(N):
    deps = sorted({j for j in [i - 1, i - 2, (i * 7 + 1) % N] if 0 <= j < i})
    args = "".join(f", svc{d}" for d in deps)
    lines.append(f"\tsvc{i} := s{i}.New(deps{args})")
    lines.append(f"\t_ = svc{i}.Start(ctx)")
    lines.append(f"\ta{i}.New(svc{i}, deps).Register(mux)")
lines += ['\t_ = http.ListenAndServe(":8080", mux)', "}", ""]
w("cmd/server/main.go", "\n".join(lines))

M_SVC = int(os.environ.get("SVC_OPS", "90"))
M_DOM = int(os.environ.get("DOM_OPS", "60"))
for i in range(N):
    K = kind(i)
    body = [f"package s{i}", "", "import (", '\t"context"', '\t"strings"', '\t"time"', "", f'\t"{MOD}/core"', f'\t"{MOD}/domain/d{i}"', ")", ""]
    for m in range(M_SVC):
        body.append(f"""func (s *Service) Op{m}(ctx context.Context, f core.Filter, owner core.ID) ([]string, error) {{
\tcfg := s.deps.Config
\tif cfg.ReadOnly && cfg.AuditEnabled {{
\t\treturn nil, core.ErrInvalid
\t}}
\tf.Limit = cfg.PageSize + {m}
\tf.Since = time.Now().Add(-cfg.CacheTTL)
\titems, err := s.repo.List(ctx, f)
\tif err != nil {{
\t\treturn nil, err
\t}}
\tmine := core.Where(items, func(x *d{i}.{K}) bool {{ return x.Owner == owner && x.Version > {m % 7} }})
\tgroups := core.GroupBy(mine, func(x *d{i}.{K}) string {{ return x.Tenant.String() + cfg.Region }})
\tvar out []string
\tfor k, g := range groups {{
\t\tfor _, x := range g {{
\t\t\tout = append(out, strings.Join([]string{{k, x.Title, string(x.ID), x.UpdatedAt.Format(time.RFC3339)}}, "/"))
\t\t}}
\t}}
\treturn core.Map(out, strings.ToUpper), nil
}}
""")
    w(f"service/s{i}/ops.go", "\n".join(body))
    body = [f"package d{i}", "", "import (", '\t"fmt"', '\t"time"', "", f'\t"{MOD}/core"', ")", ""]
    for m in range(M_DOM):
        body.append(f"""func (x *{K}) Rule{m}(now time.Time, cfg core.Config) (bool, error) {{
\tif x.Deleted || x.Version < {m % 5} {{
\t\treturn false, nil
\t}}
\tif now.Sub(x.CreatedAt) > cfg.Timeout*{m + 1} {{
\t\treturn false, fmt.Errorf("rule {m}: %s expired after %v", x.ID, cfg.Timeout)
\t}}
\tfor _, l := range x.Lines {{
\t\tif l.Quantity > cfg.MaxItems+{m} || l.Price < 0 {{
\t\t\treturn false, &core.ValidationError{{Field: l.SKU, Reason: "rule {m}"}}
\t\t}}
\t}}
\treturn x.Status == StatusActive && x.Meta["rule{m}"] != "off", nil
}}
""")
    w(f"domain/d{i}/rules.go", "\n".join(body))
