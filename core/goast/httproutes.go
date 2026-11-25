package goast

import (
	"context"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

type HTTPRouteLens struct {
	Method                string   `json:"method"`
	Path                  string   `json:"path"`
	Line                  int      `json:"line"`
	Framework             string   `json:"framework"`
	PathParams            []string `json:"pathParams,omitempty"`
	HandlerName           string   `json:"handlerName,omitempty"`
	SampleRequestBodyJSON string   `json:"sampleRequestBodyJSON,omitempty"`
}

type HTTPExecutionResult struct {
	StatusCode int               `json:"statusCode"`
	DurationMs int64             `json:"durationMs"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body"`
}

type HTTPResponseResult = HTTPExecutionResult

type structFieldDef struct {
	Name     string
	JSONKey  string
	TypeName string
	Tag      string
}

type structDef struct {
	Name   string
	Fields []structFieldDef
}

func ScanGoHTTPRoutes(srcContent string) ([]HTTPRouteLens, error) {
	if strings.TrimSpace(srcContent) == "" {
		return []HTTPRouteLens{}, nil
	}

	fset := token.NewFileSet()
	node, err := parser.ParseFile(fset, "routes.go", srcContent, 0)
	if err != nil {
		return nil, fmt.Errorf("parse error: %w", err)
	}

	structDefs := make(map[string]*structDef)
	var structNames []string
	funcDecls := make(map[string]*ast.FuncDecl)

	collectDecl := func(n ast.Node) {
		switch d := n.(type) {
		case *ast.FuncDecl:
			if d.Name != nil {
				funcDecls[d.Name.Name] = d
			}
		case *ast.TypeSpec:
			st, ok := d.Type.(*ast.StructType)
			if !ok || st.Fields == nil {
				return
			}
			sDef := &structDef{
				Name: d.Name.Name,
			}
			for _, f := range st.Fields.List {
				typeName := formatTypeExpr(f.Type)
				tagVal := ""
				if f.Tag != nil {
					tagVal = strings.Trim(f.Tag.Value, "`")
				}
				jsonKey := extractJSONTagKey(tagVal)
				for _, id := range f.Names {
					key := jsonKey
					if key == "" {
						key = strings.ToLower(id.Name)
					}
					if key == "-" {
						continue
					}
					sDef.Fields = append(sDef.Fields, structFieldDef{
						Name:     id.Name,
						JSONKey:  key,
						TypeName: typeName,
						Tag:      tagVal,
					})
				}
			}
			if _, exists := structDefs[sDef.Name]; !exists {
				structNames = append(structNames, sDef.Name)
			}
			structDefs[sDef.Name] = sDef
		}
	}
	collectOnly := func(n ast.Node) {
		if n == nil {
			return
		}
		ast.Inspect(n, func(c ast.Node) bool {
			if c != nil {
				collectDecl(c)
			}
			return true
		})
	}

	groupPrefixes := make(map[string]string)

	var routes []HTTPRouteLens
	type pendingBody struct {
		index   int
		handler ast.Node
	}
	var pendingBodies []pendingBody

	var inspectNode func(n ast.Node) bool
	inspectNode = func(n ast.Node) bool {
		if n == nil {
			return true
		}

		collectDecl(n)

		if _, ok := n.(*ast.FuncDecl); ok {
			groupPrefixes = make(map[string]string)
		}

		if assign, ok := n.(*ast.AssignStmt); ok {
			for _, rhs := range assign.Rhs {
				if call, ok := rhs.(*ast.CallExpr); ok {
					if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
						if (sel.Sel.Name == "Group" || sel.Sel.Name == "Route") && len(call.Args) >= 1 {
							if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
								subPath := strings.Trim(lit.Value, `"`)
								parentPrefix := resolveReceiverPrefix(sel.X, groupPrefixes)
								combined := joinRoutePaths(parentPrefix, subPath)
								for _, lhs := range assign.Lhs {
									if id, ok := lhs.(*ast.Ident); ok {
										groupPrefixes[id.Name] = combined
									}
								}
							}
						}
					}
				}
			}
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}

		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}

		methodName := sel.Sel.Name
		line := fset.Position(call.Pos()).Line

		var route HTTPRouteLens
		route.Line = line

		receiverName := ""
		if xIdent, ok := sel.X.(*ast.Ident); ok {
			receiverName = xIdent.Name
		}
		receiverPrefix := resolveReceiverPrefix(sel.X, groupPrefixes)

		var handlerNode ast.Node

		switch methodName {
		case "HandleFunc", "Handle":
			if len(call.Args) >= 2 {
				if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					raw := strings.Trim(lit.Value, `"`)
					if raw == "" {
						return true
					}
					parts := strings.Fields(raw)
					if len(parts) >= 2 {
						route.Method = parts[0]
						route.Path = joinRoutePaths(receiverPrefix, parts[1])
					} else {
						route.Method = "GET"
						route.Path = joinRoutePaths(receiverPrefix, raw)
					}
					route.Framework = "net/http"
					if len(call.Args) >= 2 {
						handlerNode = call.Args[1]
					}
				}
			}
		case "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD":
			if len(call.Args) >= 2 {
				if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					raw := strings.Trim(lit.Value, `"`)
					if raw == "" {
						return true
					}
					route.Method = methodName
					route.Path = joinRoutePaths(receiverPrefix, raw)
					route.Framework = "gin/echo"
					if len(call.Args) >= 2 {
						handlerNode = call.Args[1]
					}
				}
			}
		case "Get", "Post", "Put", "Delete", "Patch", "Options", "Head":
			if receiverName == "http" {
				return true
			}
			if len(call.Args) >= 2 {
				if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					raw := strings.Trim(lit.Value, `"`)
					if !strings.HasPrefix(raw, "/") {
						return true
					}
					route.Method = strings.ToUpper(methodName)
					route.Path = joinRoutePaths(receiverPrefix, raw)
					route.Framework = "chi"
					if len(call.Args) >= 2 {
						handlerNode = call.Args[1]
					}
				}
			}
		case "Route", "Group":
			var subPrefix string
			var fnLit *ast.FuncLit

			if len(call.Args) >= 2 {
				if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					subPrefix = strings.Trim(lit.Value, `"`)
				}
				if fl, ok := call.Args[1].(*ast.FuncLit); ok {
					fnLit = fl
				}
			} else if len(call.Args) == 1 {
				if fl, ok := call.Args[0].(*ast.FuncLit); ok {
					fnLit = fl
				}
			}

			if fnLit != nil {
				fullPrefix := joinRoutePaths(receiverPrefix, subPrefix)
				savedPrefixes := make(map[string]string, len(groupPrefixes))
				for k, v := range groupPrefixes {
					savedPrefixes[k] = v
				}

				if fnLit.Type.Params != nil {
					for _, p := range fnLit.Type.Params.List {
						for _, id := range p.Names {
							groupPrefixes[id.Name] = fullPrefix
						}
					}
				}

				collectOnly(call.Fun)
				for _, arg := range call.Args {
					if arg != ast.Expr(fnLit) {
						collectOnly(arg)
						continue
					}
					collectOnly(fnLit.Type)
					if fnLit.Body != nil {
						ast.Inspect(fnLit.Body, inspectNode)
					}
				}

				groupPrefixes = savedPrefixes
				return false
			}
		}

		if route.Path != "" {
			route.PathParams = ExtractPathParameters(route.Path)

			if handlerNode != nil {
				if id, ok := handlerNode.(*ast.Ident); ok {
					route.HandlerName = id.Name
				}
			}

			if route.Method == "POST" || route.Method == "PUT" || route.Method == "PATCH" {
				pendingBodies = append(pendingBodies, pendingBody{index: len(routes), handler: handlerNode})
			}

			routes = append(routes, route)
		}

		return true
	}

	ast.Inspect(node, inspectNode)

	sort.Strings(structNames)
	for _, pb := range pendingBodies {
		targetStructName := detectStructInHandler(pb.handler, funcDecls, structNames, srcContent)
		if targetStructName == "" {
			continue
		}
		if sDef, ok := structDefs[targetStructName]; ok {
			visited := make(map[string]bool)
			routes[pb.index].SampleRequestBodyJSON = generateSampleJSONForStruct(sDef, structDefs, 0, visited)
		}
	}

	return routes, nil
}

func ScanHTTPRoutes(srcContent string) ([]HTTPRouteLens, error) {
	return ScanGoHTTPRoutes(srcContent)
}

func ExtractPathParameters(path string) []string {
	var params []string
	seen := make(map[string]bool)

	rem := path
	for {
		openIdx := strings.IndexByte(rem, '{')
		if openIdx < 0 {
			break
		}
		rem = rem[openIdx+1:]
		closeIdx := strings.IndexByte(rem, '}')
		if closeIdx < 0 {
			break
		}
		rawParam := strings.TrimSpace(rem[:closeIdx])
		rem = rem[closeIdx+1:]
		rawParam = strings.TrimSuffix(rawParam, "...")
		rawParam = strings.TrimSpace(rawParam)
		if rawParam != "" && rawParam != "$" && !seen[rawParam] {
			seen[rawParam] = true
			params = append(params, rawParam)
		}
	}

	segments := strings.Split(path, "/")
	for _, seg := range segments {
		seg = strings.TrimSpace(seg)
		if strings.HasPrefix(seg, ":") {
			p := strings.TrimPrefix(seg, ":")
			if p != "" && !seen[p] {
				seen[p] = true
				params = append(params, p)
			}
		} else if strings.HasPrefix(seg, "*") {
			p := strings.TrimPrefix(seg, "*")
			if p != "" && !seen[p] {
				seen[p] = true
				params = append(params, p)
			}
		}
	}

	return params
}

func ExecuteGoHTTPRequest(targetURL, method, headersJSON, body string, timeoutSec int) (*HTTPExecutionResult, error) {
	if timeoutSec <= 0 {
		timeoutSec = 10
	}
	timeout := time.Duration(timeoutSec) * time.Second

	headers := make(map[string]string)
	if strings.TrimSpace(headersJSON) != "" {
		_ = json.Unmarshal([]byte(headersJSON), &headers)
	}

	return ExecuteLocalHTTPRequest(targetURL, method, headers, body, timeout)
}

func ExecuteLocalHTTPRequest(targetURL, method string, headers map[string]string, body string, timeout time.Duration) (*HTTPExecutionResult, error) {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}

	normalizedMethod := strings.ToUpper(strings.TrimSpace(method))
	if normalizedMethod == "" {
		normalizedMethod = "GET"
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	var bodyReader io.Reader
	if body != "" {
		bodyReader = strings.NewReader(body)
	}

	req, err := http.NewRequestWithContext(ctx, normalizedMethod, targetURL, bodyReader)
	if err != nil {
		return nil, fmt.Errorf("invalid request: %w", err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if body != "" && req.Header.Get("Content-Type") == "" {
		trimmed := strings.TrimSpace(body)
		if (strings.HasPrefix(trimmed, "{") && strings.HasSuffix(trimmed, "}")) ||
			(strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]")) {
			req.Header.Set("Content-Type", "application/json")
		}
	}

	client := &http.Client{
		Timeout: timeout,
	}

	start := time.Now()
	resp, err := client.Do(req)
	duration := time.Since(start).Milliseconds()
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	limitReader := io.LimitReader(resp.Body, 8*1024*1024)
	respBytes, err := io.ReadAll(limitReader)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	respHeaders := make(map[string]string)
	for k, v := range resp.Header {
		respHeaders[k] = strings.Join(v, ", ")
	}

	return &HTTPExecutionResult{
		StatusCode: resp.StatusCode,
		DurationMs: duration,
		Headers:    respHeaders,
		Body:       string(respBytes),
	}, nil
}

func resolveReceiverPrefix(expr ast.Expr, scope map[string]string) string {
	if expr == nil {
		return ""
	}
	switch e := expr.(type) {
	case *ast.Ident:
		if scope != nil {
			return scope[e.Name]
		}
		return ""
	case *ast.CallExpr:
		if sel, ok := e.Fun.(*ast.SelectorExpr); ok {
			switch sel.Sel.Name {
			case "Group", "Route":
				parent := resolveReceiverPrefix(sel.X, scope)
				if len(e.Args) >= 1 {
					if lit, ok := e.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
						sub := strings.Trim(lit.Value, `"`)
						return joinRoutePaths(parent, sub)
					}
				}
				return parent
			case "With", "Use":
				return resolveReceiverPrefix(sel.X, scope)
			}
		}
	}
	return ""
}

func collapseSlashes(p string) string {
	if p == "" {
		return ""
	}
	var sb strings.Builder
	sb.Grow(len(p))
	prevSlash := false
	for i := 0; i < len(p); i++ {
		if p[i] == '/' {
			if !prevSlash {
				sb.WriteByte('/')
				prevSlash = true
			}
		} else {
			sb.WriteByte(p[i])
			prevSlash = false
		}
	}
	res := sb.String()
	if !strings.HasPrefix(res, "/") && res != "" {
		res = "/" + res
	}
	return res
}

func joinRoutePaths(parent, child string) string {
	parent = strings.TrimSpace(parent)
	child = strings.TrimSpace(child)

	if parent == "" || parent == "/" {
		if !strings.HasPrefix(child, "/") {
			return collapseSlashes("/" + child)
		}
		return collapseSlashes(child)
	}
	if child == "" || child == "/" {
		return collapseSlashes(parent)
	}

	cleanParent := strings.TrimRight(parent, "/")
	cleanChild := strings.TrimLeft(child, "/")
	return collapseSlashes(cleanParent + "/" + cleanChild)
}

func formatTypeExpr(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return "*" + formatTypeExpr(t.X)
	case *ast.ArrayType:
		return "[]" + formatTypeExpr(t.Elt)
	case *ast.SelectorExpr:
		return formatTypeExpr(t.X) + "." + t.Sel.Name
	case *ast.IndexExpr:
		return formatTypeExpr(t.X)
	default:
		return fmt.Sprintf("%v", expr)
	}
}

func extractJSONTagKey(tag string) string {
	for len(tag) > 0 {
		tag = strings.TrimSpace(tag)
		if !strings.HasPrefix(tag, "json:\"") {
			space := strings.IndexByte(tag, ' ')
			if space < 0 {
				break
			}
			tag = tag[space+1:]
			continue
		}
		tag = tag[len("json:\""):]
		quote := strings.IndexByte(tag, '"')
		if quote < 0 {
			break
		}
		val := tag[:quote]
		parts := strings.Split(val, ",")
		return strings.TrimSpace(parts[0])
	}
	return ""
}

func detectStructInHandler(handlerNode ast.Node, funcDecls map[string]*ast.FuncDecl, sortedStructNames []string, srcContent string) string {
	var body *ast.BlockStmt

	if handlerNode != nil {
		if id, ok := handlerNode.(*ast.Ident); ok {
			if fd, exists := funcDecls[id.Name]; exists {
				body = fd.Body
			}
		} else if fnLit, ok := handlerNode.(*ast.FuncLit); ok {
			body = fnLit.Body
		}
	}

	if body != nil {
		var detectedType string
		ast.Inspect(body, func(n ast.Node) bool {
			if detectedType != "" {
				return false
			}
			if call, ok := n.(*ast.CallExpr); ok {
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
					name := sel.Sel.Name
					if name == "Decode" || name == "BindJSON" || name == "ShouldBindJSON" || name == "Bind" || name == "ShouldBind" {
						for _, arg := range call.Args {
							if unary, ok := arg.(*ast.UnaryExpr); ok && unary.Op == token.AND {
								if argId, ok := unary.X.(*ast.Ident); ok {
									detectedType = findVarTypeNameInBody(body, argId.Name)
									if detectedType != "" {
										return false
									}
								}
							}
						}
					}
				}
			}
			if valSpec, ok := n.(*ast.ValueSpec); ok {
				if valSpec.Type != nil {
					tName := formatTypeExpr(valSpec.Type)
					clean := strings.TrimPrefix(tName, "*")
					for _, sName := range sortedStructNames {
						if clean == sName {
							detectedType = sName
							return false
						}
					}
				}
			}
			return true
		})
		if detectedType != "" {
			return detectedType
		}
	}

	for _, sName := range sortedStructNames {
		if strings.Contains(srcContent, sName) {
			return sName
		}
	}

	return ""
}

func findVarTypeNameInBody(body *ast.BlockStmt, varName string) string {
	var typeName string
	ast.Inspect(body, func(n ast.Node) bool {
		if typeName != "" {
			return false
		}
		if valSpec, ok := n.(*ast.ValueSpec); ok {
			for _, id := range valSpec.Names {
				if id.Name == varName && valSpec.Type != nil {
					typeName = formatTypeExpr(valSpec.Type)
					return false
				}
			}
		}
		if assign, ok := n.(*ast.AssignStmt); ok {
			for i, lhs := range assign.Lhs {
				if id, ok := lhs.(*ast.Ident); ok && id.Name == varName && i < len(assign.Rhs) {
					switch rhs := assign.Rhs[i].(type) {
					case *ast.CompositeLit:
						if rhs.Type != nil {
							typeName = formatTypeExpr(rhs.Type)
							return false
						}
					case *ast.UnaryExpr:
						if rhs.Op == token.AND {
							if comp, ok := rhs.X.(*ast.CompositeLit); ok && comp.Type != nil {
								typeName = formatTypeExpr(comp.Type)
								return false
							}
						}
					case *ast.CallExpr:
						if idFun, ok := rhs.Fun.(*ast.Ident); ok && idFun.Name == "new" && len(rhs.Args) >= 1 {
							typeName = formatTypeExpr(rhs.Args[0])
							return false
						}
					}
				}
			}
		}
		return true
	})
	return strings.TrimPrefix(typeName, "*")
}

func generateSampleJSONForStruct(sDef *structDef, allDefs map[string]*structDef, depth int, visited map[string]bool) string {
	if depth > 3 || visited[sDef.Name] {
		return "{}"
	}
	visited[sDef.Name] = true
	defer func() { visited[sDef.Name] = false }()

	sampleMap := make(map[string]any)
	for _, f := range sDef.Fields {
		sampleMap[f.JSONKey] = sampleValueForType(f.TypeName, f.JSONKey, allDefs, depth+1, visited)
	}

	b, err := json.MarshalIndent(sampleMap, "", "  ")
	if err != nil {
		return "{}"
	}
	return string(b)
}

func sampleValueForType(typeName, key string, allDefs map[string]*structDef, depth int, visited map[string]bool) any {
	cleanType := strings.TrimPrefix(typeName, "*")
	switch cleanType {
	case "string":
		return "sample_" + key
	case "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64":
		return 1
	case "float32", "float64":
		return 1.0
	case "bool":
		return true
	default:
		if strings.HasPrefix(cleanType, "[]") {
			elemType := strings.TrimPrefix(cleanType, "[]")
			elemVal := sampleValueForType(elemType, key, allDefs, depth+1, visited)
			if elemVal != nil {
				return []any{elemVal}
			}
			return []any{}
		}
		if nestedDef, ok := allDefs[cleanType]; ok && depth < 3 && !visited[cleanType] {
			nestedMap := make(map[string]any)
			visited[cleanType] = true
			for _, f := range nestedDef.Fields {
				nestedMap[f.JSONKey] = sampleValueForType(f.TypeName, f.JSONKey, allDefs, depth+1, visited)
			}
			visited[cleanType] = false
			return nestedMap
		}
		return nil
	}
}
