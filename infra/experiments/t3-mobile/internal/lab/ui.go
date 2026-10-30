package lab

import (
	"bytes"
	"context"
	"encoding/xml"
	"fmt"
	"image"
	"io"
	"regexp"
	"strconv"
	"time"
)

// Node is one element of a UI Automator hierarchy dump.
type Node struct {
	Text, Desc string
	Bounds     image.Rectangle
}

var boundsPattern = regexp.MustCompile(`^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$`)

// ParseHierarchy flattens a `uiautomator dump` document into its nodes.
func ParseHierarchy(document []byte) ([]Node, error) {
	var nodes []Node
	decoder := xml.NewDecoder(bytes.NewReader(document))
	for {
		token, err := decoder.Token()
		if err != nil {
			if err == io.EOF {
				return nodes, nil
			}
			return nil, fmt.Errorf("parse UI hierarchy: %w", err)
		}
		element, ok := token.(xml.StartElement)
		if !ok || element.Name.Local != "node" {
			continue
		}
		var node Node
		for _, attr := range element.Attr {
			switch attr.Name.Local {
			case "text":
				node.Text = attr.Value
			case "content-desc":
				node.Desc = attr.Value
			case "bounds":
				match := boundsPattern.FindStringSubmatch(attr.Value)
				if match == nil {
					return nil, fmt.Errorf("parse UI hierarchy: bounds %q", attr.Value)
				}
				var corners [4]int
				for i := range corners {
					corners[i], _ = strconv.Atoi(match[i+1])
				}
				node.Bounds = image.Rect(corners[0], corners[1], corners[2], corners[3])
			}
		}
		nodes = append(nodes, node)
	}
}

// Find returns the first node matching the predicate.
func Find(nodes []Node, match func(Node) bool) (Node, bool) {
	for _, node := range nodes {
		if match(node) {
			return node, true
		}
	}
	return Node{}, false
}

// Labelled matches a node by its visible text or accessibility label.
func Labelled(label string) func(Node) bool {
	return func(node Node) bool { return node.Text == label || node.Desc == label }
}

// Screen reads the device's current UI hierarchy.
func (d *Device) Screen(ctx context.Context) ([]Node, error) {
	if _, err := d.ADB(ctx, "shell", "uiautomator", "dump", "/sdcard/ui.xml"); err != nil {
		return nil, err
	}
	document, err := d.ADB(ctx, "exec-out", "cat", "/sdcard/ui.xml")
	if err != nil {
		return nil, err
	}
	return ParseHierarchy(document)
}

// Shows reports whether a node with the label is on screen.
func (d *Device) Shows(ctx context.Context, label string) (bool, error) {
	nodes, err := d.Screen(ctx)
	if err != nil {
		return false, err
	}
	_, ok := Find(nodes, Labelled(label))
	return ok, nil
}

// WaitFor polls the screen until a node matches or the timeout passes.
func (d *Device) WaitFor(ctx context.Context, timeout time.Duration, match func(Node) bool) (Node, error) {
	deadline := time.Now().Add(timeout)
	for {
		nodes, err := d.Screen(ctx)
		if err != nil {
			return Node{}, err
		}
		if node, ok := Find(nodes, match); ok {
			return node, nil
		}
		if time.Now().After(deadline) {
			return Node{}, fmt.Errorf("no matching element on screen after %s", timeout)
		}
		if err := sleep(ctx, time.Second); err != nil {
			return Node{}, err
		}
	}
}

// Tap taps the node's centre. UI Automator dumps briefly drop input, so it
// waits a second first.
func (d *Device) Tap(ctx context.Context, node Node) error {
	if err := sleep(ctx, time.Second); err != nil {
		return err
	}
	centre := node.Bounds.Min.Add(node.Bounds.Max).Div(2)
	_, err := d.ADB(ctx, "shell", "input", "tap", strconv.Itoa(centre.X), strconv.Itoa(centre.Y))
	return err
}

func sleep(ctx context.Context, duration time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(duration):
		return nil
	}
}
