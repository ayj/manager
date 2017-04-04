package main

import (
	"flag"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/golang/glog"
	"github.com/golang/sync/errgroup"
	"github.com/montanaflynn/stats"
)

var (
	namespace = flag.String("namespace", "", "Kubernetes namespace for selecting pods to sample envoty stats")
	selector  = flag.String("selector", "", "Kubernetes selector for selecting pods to sample envoy stats")
	port      = flag.String("host", "15000", "Port on which to query envoy for stats")
)

type envoyStats map[string]int

func sample(pod, namespace string, ch chan<- envoyStats) error {
	args := []string{
		"exec",
		// "--stdin",
		// "--tty",
		"--namespace", namespace,
		pod,
		"--container", "proxy",
		"--", "curl", "-s", fmt.Sprintf("localhost:%v/stats", *port),
	}
	glog.Infof("kubectl %v", strings.Join(args, " "))
	out, err := exec.Command("kubectl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("sampling failed for %v: %q %v", pod, string(out), err)
	}
	stats := make(envoyStats)
	for _, line := range strings.Split(string(out), "\n") {
		if tuple := strings.Split(line, ": "); len(tuple) == 2 {
			name := tuple[0]
			value, err := strconv.Atoi(tuple[1])
			if err != nil {
				continue
			}
			stats[name] = value
		}
	}
	ch <- stats
	return nil
}

func matchingPodNames(namespace, selector string) ([]string, error) {
	args := []string{
		"get", "pods",
		"--output", "jsonpath={.items..metadata.name}",
		"--namespace", namespace,
		"--selector", selector,
	}
	out, err := exec.Command("kubectl", args...).CombinedOutput()
	if err != nil {
		return nil, err
	}
	return strings.Split(string(out), " "), nil
}

func foreach(namespace, selector string, fn func(string) error) error {
	names, err := matchingPodNames(namespace, selector)
	if err != nil {
		return err
	}
	glog.Infof("foreach %q", names)
	var g errgroup.Group
	for _, name := range names {
		name := name
		g.Go(func() error { return fn(name) })
	}
	return g.Wait()
}

func main() {
	flag.Parse()

	// reset counters
	if err := foreach(*namespace, *selector, func(name string) error {
		args := strings.Split(fmt.Sprintf("kubectl exec -it -n %s %s -- curl -s localhost:15000/reset_counters",
			*namespace, name), " ")
		if out, err := exec.Command(args[0], args[1:]...).CombinedOutput(); err != nil {
			return fmt.Errorf("%v: %v", string(out), err)
		}
		return nil
	}); err != nil {
		glog.Exit(err)
	}

	// gather envoy stats samples in across all test apps in parallel.
	statc := make(chan envoyStats)
	donec := make(chan struct{})
	total := make(map[string][]int)
	go func() {
		for stat := range statc {
			for name, value := range stat {
				if _, ok := total[name]; !ok {
					total[name] = []int{}
				}
				total[name] = append(total[name], value)
			}
		}
		donec <- struct{}{}
	}()

	time.Sleep(10 * time.Second)

	if err := foreach(*namespace, *selector, func(name string) error {
		return sample(name, *namespace, statc)
	}); err != nil {
		glog.Exit(err)
	}

	// Stop accumulating stats
	close(statc)
	<-donec

	for name, value := range total {
		calcs := []struct {
			name string
			fn   func(data stats.Float64Data) (float64, error)
		}{
			{"min", stats.Min},
			{"max", stats.Max},
			{"mean", stats.Mean},
			{"median", stats.Median},
			{"stdDevP", stats.StdDevP},
			{"stdDevS", stats.StdDevS},
		}

		out := []string{name}
		for _, c := range calcs {
			r, err := c.fn(stats.LoadRawData(value))
			if err != nil {
				glog.Exitf("Error calculating %s for %q: %v", c.name, name, err)
			}
			out = append(out, fmt.Sprintf("%v:%v", c.name, int(r)))
		}
		fmt.Println(strings.Join(out, ", "))
	}
}
