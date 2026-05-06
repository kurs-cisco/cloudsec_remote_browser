package contracts

type BrokerDecision string

const (
	BrokerDecisionAllowed     BrokerDecision = "allowed"
	BrokerDecisionBlocked     BrokerDecision = "blocked"
	BrokerDecisionUnsupported BrokerDecision = "unsupported"
)

type BrokerReason string

const (
	BrokerReasonPolicyAllowed        BrokerReason = "policy-allowed"
	BrokerReasonPolicyBlocked        BrokerReason = "policy-blocked"
	BrokerReasonUnsupportedDirection BrokerReason = "unsupported-direction"
	BrokerReasonPayloadTooLarge      BrokerReason = "payload-too-large"
	BrokerReasonUnsupportedMimeType  BrokerReason = "unsupported-mime-type"
	BrokerReasonScanRequired         BrokerReason = "scan-required"
)

type BrokerAuditContext struct {
	SessionID     string            `json:"sessionId"`
	TenantID      string            `json:"tenantId"`
	ProfileID     string            `json:"profileId,omitempty"`
	PolicyID      string            `json:"policyId,omitempty"`
	UserID        string            `json:"userId,omitempty"`
	Provider      string            `json:"provider,omitempty"`
	ProviderRoute string            `json:"providerRoute,omitempty"`
	TraceID       string            `json:"traceId,omitempty"`
	Metadata      map[string]string `json:"metadata,omitempty"`
}

type FileBrokerRequest struct {
	BrokerAuditContext
	Direction    string            `json:"direction"`
	FileName     string            `json:"fileName"`
	MimeType     string            `json:"mimeType,omitempty"`
	SizeBytes    int64             `json:"sizeBytes"`
	SHA256       string            `json:"sha256,omitempty"`
	StorageRef   string            `json:"storageRef,omitempty"`
	Disposition  string            `json:"disposition,omitempty"`
	PolicyLabels []string          `json:"policyLabels,omitempty"`
	Attributes   map[string]string `json:"attributes,omitempty"`
}

type ClipboardBrokerRequest struct {
	BrokerAuditContext
	Direction    string   `json:"direction"`
	Format       string   `json:"format"`
	SizeBytes    int64    `json:"sizeBytes"`
	Text         string   `json:"text,omitempty"`
	PolicyLabels []string `json:"policyLabels,omitempty"`
}

type BrokerResponse struct {
	ID               string         `json:"id"`
	Decision         BrokerDecision `json:"decision"`
	Reason           BrokerReason   `json:"reason"`
	SessionID        string         `json:"sessionId"`
	TenantID         string         `json:"tenantId"`
	Direction        string         `json:"direction"`
	Action           string         `json:"action"`
	FallbackProvider string         `json:"fallbackProvider,omitempty"`
	ReleaseRef       string         `json:"releaseRef,omitempty"`
	AuditID          string         `json:"auditId"`
	TTLSeconds       int            `json:"ttlSeconds"`
}

type BrokerSummary struct {
	Service         string          `json:"service"`
	RequestsTotal   int             `json:"requestsTotal"`
	Allowed         int             `json:"allowed"`
	Blocked         int             `json:"blocked"`
	Unsupported     int             `json:"unsupported"`
	BytesTotal      int64           `json:"bytesTotal"`
	LastDecision    *BrokerResponse `json:"lastDecision,omitempty"`
	DecisionReasons map[string]int  `json:"decisionReasons"`
}
