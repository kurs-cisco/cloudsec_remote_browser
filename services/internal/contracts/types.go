package contracts

type Viewport struct {
	Width             int     `json:"width,omitempty"`
	Height            int     `json:"height,omitempty"`
	DeviceScaleFactor float64 `json:"deviceScaleFactor,omitempty"`
}

type EdgeBootstrapRequest struct {
	TransactionID    string         `json:"transactionId"`
	TargetURL        string         `json:"targetUrl"`
	OrgID            string         `json:"orgId"`
	BoundaryType     string         `json:"boundaryType"`
	BoundaryID       string         `json:"boundaryId"`
	OriginID         string         `json:"originId"`
	OriginType       string         `json:"originType"`
	TenantID         string         `json:"tenantId"`
	ProfileID        string         `json:"profileId"`
	Policy           string         `json:"policy"`
	ContractVersion  string         `json:"contractVersion,omitempty"`
	RequestKind      string         `json:"requestKind,omitempty"`
	OriginalMethod   string         `json:"originalMethod,omitempty"`
	Provider         string         `json:"provider,omitempty"`
	ProviderCategory string         `json:"providerCategory,omitempty"`
	FallbackProvider string         `json:"fallbackProvider,omitempty"`
	FallbackReason   string         `json:"fallbackReason,omitempty"`
	Nonce            string         `json:"nonce"`
	KeyID            string         `json:"keyId"`
	UpstreamHost     string         `json:"upstreamHost"`
	UpstreamScheme   string         `json:"upstreamScheme"`
	UpstreamPort     string         `json:"upstreamPort"`
	Viewport         *Viewport      `json:"viewport,omitempty"`
	Experiments      map[string]any `json:"experiments,omitempty"`
	Client           map[string]any `json:"client,omitempty"`
	PublicBaseURL    string         `json:"publicBaseUrl,omitempty"`
	PublicWsURL      string         `json:"publicWsUrl,omitempty"`
}

type EdgeBootstrapResponse struct {
	SessionID         string             `json:"sessionId"`
	HandoffURL        string             `json:"handoffUrl"`
	ViewerEntry       string             `json:"viewerEntryMode"`
	GatewayRegion     string             `json:"gatewayRegion,omitempty"`
	GatewayAssignment *GatewayAssignment `json:"gatewayAssignment,omitempty"`
	WorkerAssignment  *WorkerAssignment  `json:"workerAssignment,omitempty"`
	Transport         *GatewayTransport  `json:"transport,omitempty"`
	WorkerBridge      *WorkerBridge      `json:"workerBridge,omitempty"`
}

type SessionPlacement struct {
	GatewayAssignment *GatewayAssignment `json:"gatewayAssignment,omitempty"`
	WorkerAssignment  *WorkerAssignment  `json:"workerAssignment,omitempty"`
}

type GatewayAssignment struct {
	SessionID     string `json:"sessionId"`
	GatewayID     string `json:"gatewayId"`
	Region        string `json:"region"`
	WorkerID      string `json:"workerId,omitempty"`
	RelayMode     string `json:"relayMode,omitempty"`
	PublicBaseURL string `json:"publicBaseUrl,omitempty"`
	PublicWsURL   string `json:"publicWsUrl,omitempty"`
}

type WorkerAssignment struct {
	SessionID        string `json:"sessionId"`
	WorkerID         string `json:"workerId"`
	Region           string `json:"region,omitempty"`
	RuntimeClass     string `json:"runtimeClass,omitempty"`
	NodePool         string `json:"nodePool,omitempty"`
	AvailabilityZone string `json:"availabilityZone,omitempty"`
}

type MediaGatewaySessionRequest struct {
	SessionID          string            `json:"sessionId"`
	TenantID           string            `json:"tenantId"`
	ProfileID          string            `json:"profileId,omitempty"`
	TargetURL          string            `json:"targetUrl,omitempty"`
	ViewerEntryMode    string            `json:"viewerEntryMode,omitempty"`
	PreferredTransport string            `json:"preferredTransport,omitempty"`
	Generation         int               `json:"generation,omitempty"`
	ViewerToken        string            `json:"viewerToken,omitempty"`
	WorkerToken        string            `json:"workerToken,omitempty"`
	Client             map[string]any    `json:"client,omitempty"`
	Experiments        map[string]any    `json:"experiments,omitempty"`
	PublicBaseURL      string            `json:"publicBaseUrl,omitempty"`
	PublicWsURL        string            `json:"publicWsUrl,omitempty"`
	GatewayAssignment  GatewayAssignment `json:"gatewayAssignment"`
	WorkerAssignment   WorkerAssignment  `json:"workerAssignment"`
}

type GatewayTransport struct {
	Preferred        string                      `json:"preferred"`
	Supported        []string                    `json:"supported"`
	ViewerURL        string                      `json:"viewerUrl"`
	SignalingURL     string                      `json:"signalingUrl,omitempty"`
	MediaRelayURL    string                      `json:"mediaRelayUrl,omitempty"`
	MediaGatewayURL  string                      `json:"mediaGatewayUrl,omitempty"`
	MediaPlaneMode   string                      `json:"mediaPlaneMode,omitempty"`
	Protocol         string                      `json:"protocol,omitempty"`
	InputPointerName string                      `json:"inputPointerName,omitempty"`
	InputControlName string                      `json:"inputControlName,omitempty"`
	MediaTermination *MediaTerminationCapability `json:"mediaTermination,omitempty"`
}

type MediaTerminationCapability struct {
	Mode                        string `json:"mode"`
	MediaPlaneMode              string `json:"mediaPlaneMode,omitempty"`
	Protocol                    string `json:"protocol,omitempty"`
	RelayMode                   string `json:"relayMode"`
	RelayModeAcceptanceState    string `json:"relayModeAcceptanceState"`
	GatewayTerminatesSignaling  bool   `json:"gatewayTerminatesSignaling"`
	GatewayTerminatesMedia      bool   `json:"gatewayTerminatesMedia"`
	WorkerAddressExposure       string `json:"workerAddressExposure"`
	DirectWorkerExposureAllowed bool   `json:"directWorkerExposureAllowed"`
	Wave2AcceptanceComplete     bool   `json:"wave2AcceptanceComplete"`
	ImplementationStatus        string `json:"implementationStatus"`
	ImplementationStatusDetail  string `json:"implementationStatusDetail,omitempty"`
}

type WorkerBridge struct {
	BridgeID         string `json:"bridgeId"`
	RelayMode        string `json:"relayMode"`
	MediaRelayURL    string `json:"mediaRelayUrl,omitempty"`
	MediaGatewayURL  string `json:"mediaGatewayUrl,omitempty"`
	MediaDirection   string `json:"mediaDirection,omitempty"`
	Protocol         string `json:"protocol,omitempty"`
	InputPointerName string `json:"inputPointerName,omitempty"`
	InputControlName string `json:"inputControlName,omitempty"`
}

type RuntimeSessionRequest struct {
	TargetURL        string            `json:"targetUrl"`
	Viewport         *Viewport         `json:"viewport,omitempty"`
	Experiments      map[string]any    `json:"experiments,omitempty"`
	Client           map[string]any    `json:"client,omitempty"`
	PublicBaseURL    string            `json:"publicBaseUrl,omitempty"`
	PublicWsURL      string            `json:"publicWsUrl,omitempty"`
	RequestContext   map[string]any    `json:"requestContext,omitempty"`
	SessionPlacement *SessionPlacement `json:"sessionPlacement,omitempty"`
	Transport        *GatewayTransport `json:"transport,omitempty"`
	WorkerBridge     *WorkerBridge     `json:"workerBridge,omitempty"`
}

type RuntimeSessionUpdateRequest struct {
	SessionPlacement *SessionPlacement `json:"sessionPlacement,omitempty"`
	Transport        *GatewayTransport `json:"transport,omitempty"`
	WorkerBridge     *WorkerBridge     `json:"workerBridge,omitempty"`
}

type RuntimeSessionResponse struct {
	SessionID            string             `json:"sessionId"`
	HandoffURL           string             `json:"handoffUrl,omitempty"`
	ViewerURL            string             `json:"viewerUrl,omitempty"`
	ViewerEntry          string             `json:"viewerEntryMode,omitempty"`
	ViewerSignalingToken string             `json:"viewerSignalingToken,omitempty"`
	ViewerToken          string             `json:"viewerToken,omitempty"`
	WorkerToken          string             `json:"workerToken,omitempty"`
	Generation           int                `json:"generation,omitempty"`
	GatewayAssignment    *GatewayAssignment `json:"gatewayAssignment,omitempty"`
	WorkerAssignment     *WorkerAssignment  `json:"workerAssignment,omitempty"`
	Transport            *GatewayTransport  `json:"transport,omitempty"`
	WorkerBridge         *WorkerBridge      `json:"workerBridge,omitempty"`
}

type MediaGatewaySessionResponse struct {
	SessionID         string            `json:"sessionId"`
	ViewerEntryMode   string            `json:"viewerEntryMode,omitempty"`
	GatewayAssignment GatewayAssignment `json:"gatewayAssignment"`
	WorkerAssignment  WorkerAssignment  `json:"workerAssignment"`
	Transport         GatewayTransport  `json:"transport"`
	WorkerBridge      WorkerBridge      `json:"workerBridge"`
}
