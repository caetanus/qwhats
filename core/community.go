package main

// A community, as WhatsApp Web's community view lists it: the announcements group ("Avisos")
// pinned on top, the groups we are in, and the ones we may join with their member counts; and
// joining one (WASmaxGroupsJoinLinkedGroupRPC).

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/types"
)

// SubGroup: a community's group we are not in.
type SubGroup struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Size int    `json:"size,omitempty"`
	Pic  string `json:"pic,omitempty"`
}

type CommunityView struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	Pic       string     `json:"pic,omitempty"`
	Announce  *Chat      `json:"announce,omitempty"`
	Joined    []Chat     `json:"joined"`
	Available []SubGroup `json:"available"`
}

func (a *Account) inGroup(id string) bool {
	g, ok := a.core.store.group(a.ID, id)
	if !ok {
		return false
	}
	for _, p := range g.Participants {
		if a.isMe(p.ID) {
			return true
		}
	}
	return false
}

func (a *Account) communityView(id string) (CommunityView, error) {
	j, err := parseJID(id)
	if err != nil {
		return CommunityView{}, err
	}
	v := CommunityView{ID: id, Name: a.chatName(id), Joined: []Chat{}, Available: []SubGroup{}}
	if p := a.communityPic(id); p != "" {
		v.Pic = p
	}
	subs, err := a.client.GetSubGroups(ctx, j)
	if err != nil {
		return v, err
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)
	for _, s := range subs {
		sid := s.JID.String()
		joined := a.inGroup(sid)
		if s.IsDefaultSubGroup || joined {
			a.core.store.ensureChat(a.ID, sid)
			if s.Name != "" {
				a.core.store.setChatName(a.ID, sid, s.Name)
			}
			c, _ := a.core.store.chat(a.ID, sid)
			fc := a.fullChat(c)
			if s.IsDefaultSubGroup {
				fc.Name = "Avisos"
				v.Announce = &fc
			} else {
				v.Joined = append(v.Joined, fc)
			}
			continue
		}
		sg := SubGroup{ID: sid, Name: s.Name}
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			sg.Size = a.linkedGroupSize(j, s.JID)
			mu.Lock()
			v.Available = append(v.Available, sg)
			mu.Unlock()
		}()
	}
	wg.Wait()
	// the biggest first, as WhatsApp Web lists them
	for i := 1; i < len(v.Available); i++ {
		for k := i; k > 0 && v.Available[k].Size > v.Available[k-1].Size; k-- {
			v.Available[k], v.Available[k-1] = v.Available[k-1], v.Available[k]
		}
	}
	return v, nil
}

// linkedGroupSize: a community group's member count, which a non-member may ask its community
// for (get_linked_group: <query_linked type="sub_group">).
func (a *Account) linkedGroupSize(community, sub types.JID) int {
	res, err := a.client.DangerousInternals().SendGroupIQ(ctx, whatsmeow.DangerousInfoQueryType("get"), community,
		waBinary.Node{Tag: "query_linked", Attrs: waBinary.Attrs{"type": "sub_group", "jid": sub}})
	if err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: linked group:", err)
		return 0
	}
	var find func(n waBinary.Node) int
	find = func(n waBinary.Node) int {
		if v, ok := n.Attrs["size"]; ok {
			if k, err := strconv.Atoi(fmt.Sprint(v)); err == nil {
				return k
			}
		}
		for _, c := range n.GetChildren() {
			if k := find(c); k > 0 {
				return k
			}
		}
		return 0
	}
	return find(*res)
}

// joinCommunityGroup: in, through the community (no invite needed), then its chat.
func (a *Account) joinCommunityGroup(communityID, subID string) (Chat, error) {
	cj, err := parseJID(communityID)
	if err != nil {
		return Chat{}, err
	}
	sj, err := parseJID(subID)
	if err != nil {
		return Chat{}, err
	}
	if _, err := a.client.DangerousInternals().SendGroupIQ(ctx, whatsmeow.DangerousInfoQueryType("set"), cj,
		waBinary.Node{Tag: "join_linked_group", Attrs: waBinary.Attrs{"jid": sj}}); err != nil {
		return Chat{}, err
	}
	if _, err := a.sendQueryGroup(subID); err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: joined group info:", err)
	}
	if !a.inGroup(subID) {
		return Chat{}, errors.New("the community did not let us in (it may need an admin's approval)")
	}
	a.systemRow(subID, "gp2", "linked_group_join", []string{a.me()}, time.Time{})
	return a.openChat(subID), nil
}
