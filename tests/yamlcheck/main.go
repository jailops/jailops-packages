// yamlcheck FILE...: parses each workflow with yaml.v3 and checks the structure GitHub needs (on, jobs, runs-on, steps).
package main

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

func main() {
	bad := 0
	for _, f := range os.Args[1:] {
		b, err := os.ReadFile(f)
		if err != nil {
			fmt.Println("FAIL", err)
			bad++
			continue
		}
		var d map[string]any
		if err := yaml.Unmarshal(b, &d); err != nil {
			fmt.Printf("FAIL %s: %v\n", f, err)
			bad++
			continue
		}
		if _, ok := d["on"]; !ok {
			fmt.Printf("FAIL %s: no 'on'\n", f)
			bad++
		}
		jobs, ok := d["jobs"].(map[string]any)
		if !ok || len(jobs) == 0 {
			fmt.Printf("FAIL %s: no jobs\n", f)
			bad++
			continue
		}
		for name, j := range jobs {
			m, _ := j.(map[string]any)
			if m["runs-on"] == nil {
				fmt.Printf("FAIL %s: job %s has no runs-on\n", f, name)
				bad++
			}
			if steps, _ := m["steps"].([]any); len(steps) == 0 && m["uses"] == nil {
				fmt.Printf("FAIL %s: job %s has no steps\n", f, name)
				bad++
			}
		}
		fmt.Printf("ok %s (%d jobs)\n", f, len(jobs))
	}
	if bad > 0 {
		os.Exit(1)
	}
}
