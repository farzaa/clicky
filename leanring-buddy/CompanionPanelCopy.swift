//
//  CompanionPanelCopy.swift
//  leanring-buddy
//
//  Localized menu-bar panel copy kept out of the SwiftUI layout tree.
//

enum SpiderAppLanguage: String, CaseIterable {
    case english = "English"
    case portuguese = "Portuguese"
    case spanish = "Spanish"

    static func normalized(_ rawValue: String) -> SpiderAppLanguage {
        SpiderAppLanguage(rawValue: rawValue) ?? .english
    }
}

enum SpiderPanelCopy {
    static func text(_ key: String, language: SpiderAppLanguage) -> String {
        guard language != .english else { return key }
        return translations[key]?[language] ?? key
    }

    private static let translations: [String: [SpiderAppLanguage: String]] = [
        "Build the right campaign\nbefore you spend.": [
            .portuguese: "Crie a campanha certa\nantes de gastar.",
            .spanish: "Crea la campaña correcta\nantes de gastar.",
        ],
        "Spider shows what to click, what to avoid,\nand when to stop before you spend.": [
            .portuguese: "Spider mostra onde clicar, o que evitar\ne quando parar antes de gastar.",
            .spanish: "Spider muestra dónde hacer clic, qué evitar\ny cuándo parar antes de gastar.",
        ],
        "Start with your offer": [
            .portuguese: "Comece pela sua oferta",
            .spanish: "Empieza por tu oferta",
        ],
        "Tell Spider what you’re selling. It will turn your\noffer into a Meta campaign direction.": [
            .portuguese: "Diga ao Spider o que você vende. Ele transforma\nsua oferta em uma direção de campanha.",
            .spanish: "Dile a Spider qué vendes. Convertirá\ntu oferta en una dirección de campaña.",
        ],
        "Describe your offer": [
            .portuguese: "Descreva sua oferta",
            .spanish: "Describe tu oferta",
        ],
        "Example: A $97 AI productivity course\nfor freelancers": [
            .portuguese: "Exemplo: Um curso de produtividade com IA\npara freelancers",
            .spanish: "Ejemplo: Un curso de productividad con IA\npara freelancers",
        ],
        "Mission": [
            .portuguese: "Missão",
            .spanish: "Misión",
        ],
        "What should this campaign do?": [
            .portuguese: "O que esta campanha deve fazer?",
            .spanish: "¿Qué debe hacer esta campaña?",
        ],
        "Sell a product": [
            .portuguese: "Vender um produto",
            .spanish: "Vender un producto",
        ],
        "Drive purchases or paid signups.": [
            .portuguese: "Gerar compras ou inscrições pagas.",
            .spanish: "Generar compras o registros pagos.",
        ],
        "Get leads": [
            .portuguese: "Captar leads",
            .spanish: "Captar leads",
        ],
        "Collect emails, forms, or contacts.": [
            .portuguese: "Coletar emails, formulários ou contatos.",
            .spanish: "Recolectar emails, formularios o contactos.",
        ],
        "Book calls": [
            .portuguese: "Agendar calls",
            .spanish: "Agendar llamadas",
        ],
        "Get people to schedule a call.": [
            .portuguese: "Fazer pessoas agendarem uma call.",
            .spanish: "Hacer que las personas agenden una llamada.",
        ],
        "Grow a newsletter": [
            .portuguese: "Crescer newsletter",
            .spanish: "Crecer newsletter",
        ],
        "Send people to subscribe.": [
            .portuguese: "Levar pessoas para se inscreverem.",
            .spanish: "Enviar personas a suscribirse.",
        ],
        "Validate an offer": [
            .portuguese: "Validar uma oferta",
            .spanish: "Validar una oferta",
        ],
        "Test demand before building more.": [
            .portuguese: "Testar demanda antes de construir mais.",
            .spanish: "Probar demanda antes de construir más.",
        ],
        "Who is this for?": [
            .portuguese: "Para quem é isso?",
            .spanish: "¿Para quién es esto?",
        ],
        "Spider needs to know the buyer before\nchoosing the campaign path.": [
            .portuguese: "Spider precisa entender o comprador antes\nde escolher o caminho da campanha.",
            .spanish: "Spider necesita entender al comprador antes\nde elegir el camino de la campaña.",
        ],
        "Target audience": [
            .portuguese: "Público-alvo",
            .spanish: "Audiencia objetivo",
        ],
        "Example: Freelancers who use AI tools\nbut struggle to stay productive": [
            .portuguese: "Exemplo: Freelancers que usam ferramentas de IA\nmas têm dificuldade de manter produtividade",
            .spanish: "Ejemplo: Freelancers que usan herramientas de IA\npero les cuesta mantenerse productivos",
        ],
        "Price / ticket": [
            .portuguese: "Preço / ticket",
            .spanish: "Precio / ticket",
        ],
        "Market": [
            .portuguese: "Mercado",
            .spanish: "Mercado",
        ],
        "Language": [
            .portuguese: "Idioma",
            .spanish: "Idioma",
        ],
        "Platform": [
            .portuguese: "Plataforma",
            .spanish: "Plataforma",
        ],
        "Set your test limit": [
            .portuguese: "Defina seu limite de teste",
            .spanish: "Define tu límite de prueba",
        ],
        "Spider won’t set or spend this. It only uses\nyour limit to keep the setup inside your plan.": [
            .portuguese: "Spider não define nem gasta isso. Ele só usa\nseu limite para manter o setup dentro do plano.",
            .spanish: "Spider no define ni gasta esto. Solo usa\ntu límite para mantener el setup dentro del plan.",
        ],
        "Total test limit": [
            .portuguese: "Limite total do teste",
            .spanish: "Límite total de prueba",
        ],
        "Daily guardrail": [
            .portuguese: "Limite diário",
            .spanish: "Límite diario",
        ],
        "Test length": [
            .portuguese: "Duração do teste",
            .spanish: "Duración de prueba",
        ],
        "You’ll type this manually inside %@.": [
            .portuguese: "Você vai digitar isso manualmente dentro do %@.",
            .spanish: "Lo escribirás manualmente dentro de %@.",
        ],
        "Let’s Go!": [
            .portuguese: "Vamos lá!",
            .spanish: "¡Vamos!",
        ],
        "Your campaign path is ready": [
            .portuguese: "O caminho da campanha está pronto",
            .spanish: "El camino de campaña está listo",
        ],
        "Spider will guide you step by step inside\n%@. You stay in control.": [
            .portuguese: "Spider vai guiar você passo a passo dentro do\n%@. Você mantém o controle.",
            .spanish: "Spider te guiará paso a paso dentro de\n%@. Tú mantienes el control.",
        ],
        "You click. Spider never spends.": [
            .portuguese: "Você clica. Spider nunca gasta.",
            .spanish: "Tú haces clic. Spider nunca gasta.",
        ],
        "Settings": [
            .portuguese: "Ajustes",
            .spanish: "Ajustes",
        ],
        "Permissions": [
            .portuguese: "Permissões",
            .spanish: "Permisos",
        ],
        "PERMISSIONS": [
            .portuguese: "PERMISSÕES",
            .spanish: "PERMISOS",
        ],
        "General": [
            .portuguese: "Geral",
            .spanish: "General",
        ],
        "Level": [
            .portuguese: "Nível",
            .spanish: "Nivel",
        ],
        "Plan": [
            .portuguese: "Plano",
            .spanish: "Plan",
        ],
        "Free · 1 campaign left": [
            .portuguese: "Grátis · 1 campanha restante",
            .spanish: "Gratis · queda 1 campaña",
        ],
        "Upgrade to PRO": [
            .portuguese: "Assinar PRO",
            .spanish: "Pasar a PRO",
        ],
        "Unlimited guided campaigns": [
            .portuguese: "Campanhas guiadas ilimitadas",
            .spanish: "Campañas guiadas ilimitadas",
        ],
        "First-step guided setup": [
            .portuguese: "Setup guiado do primeiro passo",
            .spanish: "Configuración guiada del primer paso",
        ],
        "Preflight locked": [
            .portuguese: "Preflight bloqueado",
            .spanish: "Preflight bloqueado",
        ],
        "72h Review locked": [
            .portuguese: "Revisão 72h bloqueada",
            .spanish: "Revisión 72h bloqueada",
        ],
        "Terms · Privacy Policy": [
            .portuguese: "Termos · Privacidade",
            .spanish: "Términos · Privacidad",
        ],
        "Build from Scratch": [
            .portuguese: "Criar do zero",
            .spanish: "Crear desde cero",
        ],
        "Start with your offer.": [
            .portuguese: "Comece pela sua oferta.",
            .spanish: "Empieza por tu oferta.",
        ],
        "Start": [
            .portuguese: "Começar",
            .spanish: "Empezar",
        ],
        "Back": [
            .portuguese: "Voltar",
            .spanish: "Atrás",
        ],
        "Next": [
            .portuguese: "Próximo",
            .spanish: "Siguiente",
        ],
        "Guide Me": [
            .portuguese: "Me guie",
            .spanish: "Guíame",
        ],
        "Grant": [
            .portuguese: "Permitir",
            .spanish: "Permitir",
        ],
        "Granted": [
            .portuguese: "Permitido",
            .spanish: "Permitido",
        ],
        "Find App": [
            .portuguese: "Buscar app",
            .spanish: "Buscar app",
        ],
        "Screen Recording": [
            .portuguese: "Gravação de tela",
            .spanish: "Grabación de pantalla",
        ],
        "Screen Content": [
            .portuguese: "Conteúdo da tela",
            .spanish: "Contenido de pantalla",
        ],
        "Microphone": [
            .portuguese: "Microfone",
            .spanish: "Micrófono",
        ],
        "Accessibility": [
            .portuguese: "Acessibilidade",
            .spanish: "Accesibilidad",
        ],
        "Show Spider": [
            .portuguese: "Mostrar Spider",
            .spanish: "Mostrar Spider",
        ],
        "Speech to Text": [
            .portuguese: "Fala para texto",
            .spanish: "Voz a texto",
        ],
        "Only takes a screenshot when you use the hotkey": [
            .portuguese: "Só tira screenshot quando você usa o atalho",
            .spanish: "Solo captura pantalla cuando usas el atajo",
        ],
        "Quit and reopen after granting": [
            .portuguese: "Feche e reabra depois de permitir",
            .spanish: "Cierra y reabre después de permitir",
        ],
        "CAMPAIGN DIRECTION": [
            .portuguese: "DIREÇÃO DA CAMPANHA",
            .spanish: "DIRECCIÓN DE CAMPAÑA",
        ],
        "Recommended objective": [
            .portuguese: "Objetivo recomendado",
            .spanish: "Objetivo recomendado",
        ],
        "Why this": [
            .portuguese: "Por que isso",
            .spanish: "Por qué esto",
        ],
        "Do not choose": [
            .portuguese: "Não escolha",
            .spanish: "No elijas",
        ],
        "Conversion event": [
            .portuguese: "Evento de conversão",
            .spanish: "Evento de conversión",
        ],
        "Audience": [
            .portuguese: "Público",
            .spanish: "Audiencia",
        ],
        "Creative angle": [
            .portuguese: "Ângulo criativo",
            .spanish: "Ángulo creativo",
        ],
        "Landing / tracking": [
            .portuguese: "Landing / tracking",
            .spanish: "Landing / tracking",
        ],
        "Open %@ and guide me": [
            .portuguese: "Abrir %@ e me guiar",
            .spanish: "Abrir %@ y guiarme",
        ],
        "ARTIFACTS": [
            .portuguese: "ARTEFATOS",
            .spanish: "ARTEFACTOS",
        ],
        "Campaign plan": [
            .portuguese: "Plano de campanha",
            .spanish: "Plan de campaña",
        ],
        "Creative pack": [
            .portuguese: "Pacote criativo",
            .spanish: "Pack creativo",
        ],
        "Preflight audit": [
            .portuguese: "Auditoria Preflight",
            .spanish: "Auditoría Preflight",
        ],
        "Optimization decision": [
            .portuguese: "Decisão de otimização",
            .spanish: "Decisión de optimización",
        ],
        "Tracking checklist": [
            .portuguese: "Checklist de tracking",
            .spanish: "Checklist de tracking",
        ],
        "AD MISSION": [
            .portuguese: "MISSÃO DE ADS",
            .spanish: "MISIÓN DE ADS",
        ],
        "Offer": [
            .portuguese: "Oferta",
            .spanish: "Oferta",
        ],
        "Goal": [
            .portuguese: "Objetivo",
            .spanish: "Objetivo",
        ],
        "Budget": [
            .portuguese: "Orçamento",
            .spanish: "Presupuesto",
        ],
        "Send feedback": [
            .portuguese: "Enviar feedback",
            .spanish: "Enviar feedback",
        ],
        "Bugs, rough edges, bad guidance. Useful stuff.": [
            .portuguese: "Bugs, arestas ruins, guidance ruim. Coisa útil.",
            .spanish: "Bugs, asperezas, mala guía. Cosas útiles.",
        ],
        "Quit Spider": [
            .portuguese: "Fechar Spider",
            .spanish: "Cerrar Spider",
        ],
        "Watch Onboarding Again": [
            .portuguese: "Ver onboarding de novo",
            .spanish: "Ver onboarding otra vez",
        ],
        "Voice mode": [
            .portuguese: "Modo voz",
            .spanish: "Modo voz",
        ],
        "Pointer overlay": [
            .portuguese: "Overlay do cursor",
            .spanish: "Overlay del cursor",
        ],
        "Screen guidance": [
            .portuguese: "Guia na tela",
            .spanish: "Guía en pantalla",
        ],
        "Ignored apps": [
            .portuguese: "Apps ignorados",
            .spanish: "Apps ignoradas",
        ],
        "Enter your email": [
            .portuguese: "Digite seu email",
            .spanish: "Ingresa tu email",
        ],
        "Sending...": [
            .portuguese: "Enviando...",
            .spanish: "Enviando...",
        ],
        "Send magic link": [
            .portuguese: "Enviar link mágico",
            .spanish: "Enviar enlace mágico",
        ],
        "Opening checkout...": [
            .portuguese: "Abrindo checkout...",
            .spanish: "Abriendo checkout...",
        ],
        "Opening...": [
            .portuguese: "Abrindo...",
            .spanish: "Abriendo...",
        ],
        "Billing": [
            .portuguese: "Billing",
            .spanish: "Facturación",
        ],
        "Sign in": [
            .portuguese: "Entrar",
            .spanish: "Entrar",
        ],
        "Checking": [
            .portuguese: "Checando",
            .spanish: "Revisando",
        ],
        "Account": [
            .portuguese: "Conta",
            .spanish: "Cuenta",
        ],
        "Setup": [
            .portuguese: "Setup",
            .spanish: "Setup",
        ],
        "Ready": [
            .portuguese: "Pronto",
            .spanish: "Listo",
        ],
        "Active": [
            .portuguese: "Ativo",
            .spanish: "Activo",
        ],
        "Listening": [
            .portuguese: "Ouvindo",
            .spanish: "Escuchando",
        ],
        "Processing": [
            .portuguese: "Processando",
            .spanish: "Procesando",
        ],
        "Responding": [
            .portuguese: "Respondendo",
            .spanish: "Respondiendo",
        ],
        "Checking account": [
            .portuguese: "Checando conta",
            .spanish: "Revisando cuenta",
        ],
        "Subscription required": [
            .portuguese: "Assinatura necessária",
            .spanish: "Suscripción requerida",
        ],
        "Account ready": [
            .portuguese: "Conta pronta",
            .spanish: "Cuenta lista",
        ],
        "Spider sends a magic link. No password, no client-side API key nonsense.": [
            .portuguese: "Spider envia um link mágico. Sem senha, sem API key no cliente.",
            .spanish: "Spider envía un enlace mágico. Sin contraseña ni API key en el cliente.",
        ],
        "Spider is verifying your session and subscription.": [
            .portuguese: "Spider está verificando sua sessão e assinatura.",
            .spanish: "Spider está verificando tu sesión y suscripción.",
        ],
        "Beta access is paid. Spider cannot run screen guidance or Realtime voice without an active subscription.": [
            .portuguese: "O beta é pago. Spider não roda orientação de tela nem voz Realtime sem assinatura ativa.",
            .spanish: "El beta es pago. Spider no ejecuta guía de pantalla ni voz Realtime sin suscripción activa.",
        ],
        "Your subscription is active.": [
            .portuguese: "Sua assinatura está ativa.",
            .spanish: "Tu suscripción está activa.",
        ],
        "Your trial is active.": [
            .portuguese: "Seu trial está ativo.",
            .spanish: "Tu prueba está activa.",
        ],
        "Guide the current ads platform screen": [
            .portuguese: "Guiar a tela atual da plataforma de ads",
            .spanish: "Guiar la pantalla actual de la plataforma de ads",
        ],
        "Copy Ad Mission snapshot": [
            .portuguese: "Copiar snapshot da missão",
            .spanish: "Copiar snapshot de la misión",
        ],
        "Cancel reset": [
            .portuguese: "Cancelar reset",
            .spanish: "Cancelar reinicio",
        ],
        "Confirm Ad Mission reset": [
            .portuguese: "Confirmar reset da missão",
            .spanish: "Confirmar reinicio de la misión",
        ],
        "Reset Ad Mission": [
            .portuguese: "Resetar missão",
            .spanish: "Reiniciar misión",
        ],
    ]
}
